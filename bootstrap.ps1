<#
  Levanta el home lab CI/CD y deja todo listo para usar:
    1. Crea .env (con password aleatorio) si no existe
    2. Levanta Gitea, Docker-in-Docker, Registry y Registry UI
    3. Crea el usuario admin de Gitea
    4. Genera el token del runner y levanta act_runner
    5. Crea el repo en Gitea e importa el proyecto de origen (copia en .\workspace,
       tu repo original NO se modifica) con Dockerfile + workflow
    6. Crea el cluster Kubernetes (k3d) y guarda su kubeconfig como secreto KUBECONFIG del repo
    7. Crea las ramas dev, QA, release, production y hace push (dispara los builds)

  Uso:   powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
  Es idempotente: se puede volver a ejecutar sin romper nada.
#>
param(
  [switch]$SkipImport,  # solo infraestructura, sin importar el proyecto
  [switch]$SkipK8s      # sin cluster k3d (no habra deploy)
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$EnvFile = Join-Path $PSScriptRoot '.env'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Check-Exit($what) { if ($LASTEXITCODE -ne 0) { throw "Fallo: $what (exit $LASTEXITCODE)" } }

function Read-DotEnv {
  $h = [ordered]@{}
  foreach ($line in [IO.File]::ReadAllLines($EnvFile)) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() }
  }
  return $h
}

function Set-DotEnvValue($key, $value) {
  $lines = [IO.File]::ReadAllLines($EnvFile)
  $found = $false
  $out = foreach ($l in $lines) {
    if ($l -match "^\s*$key\s*=") { $found = $true; "$key=$value" } else { $l }
  }
  if (-not $found) { $out = @($out) + "$key=$value" }
  [IO.File]::WriteAllLines($EnvFile, [string[]]$out, $Utf8NoBom)
}

# ---------------------------------------------------------------------------
Step 'Verificando Docker'
docker info --format '{{.ServerVersion}}' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker no esta corriendo. Abre Docker Desktop y vuelve a intentar.' }

# ---------------------------------------------------------------------------
function New-Password {
  $chars = [char[]]'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  # sufijo fijo para cumplir la politica de SonarQube (mayuscula, minuscula, digito, especial)
  return (-join (1..20 | ForEach-Object { $chars | Get-Random })) + '_Aa1'
}

if (-not (Test-Path $EnvFile)) {
  Step 'Creando .env con passwords aleatorios'
  [IO.File]::WriteAllText($EnvFile, [IO.File]::ReadAllText((Join-Path $PSScriptRoot '.env.example')), $Utf8NoBom)
  Set-DotEnvValue 'GITEA_ADMIN_PASSWORD' (New-Password)
}
# Variables agregadas en versiones posteriores del lab (para .env ya existentes)
$cfg = Read-DotEnv
$defaults = [ordered]@{ SONAR_PORT = '9000'; SONAR_DB_PASSWORD = (New-Password); SONAR_ADMIN_PASSWORD = (New-Password); SONAR_TOKEN = '' }
foreach ($k in $defaults.Keys) {
  $missing = -not $cfg.Contains($k)
  $emptyPassword = ($k -like '*PASSWORD') -and -not $missing -and [string]::IsNullOrWhiteSpace($cfg[$k])
  if ($missing -or $emptyPassword) { Set-DotEnvValue $k $defaults[$k] }
}
$cfg = Read-DotEnv
$GiteaUrl = "http://localhost:$($cfg.GITEA_HTTP_PORT)"
$SonarUrl = "http://localhost:$($cfg.SONAR_PORT)"

# ---------------------------------------------------------------------------
Step 'Levantando Gitea, dind, registry, registry-ui y SonarQube'
docker compose up -d gitea dind registry registry-ui sonar-db sonarqube
Check-Exit 'docker compose up'

Step 'Esperando a que Gitea este healthy'
$deadline = (Get-Date).AddMinutes(3)
do {
  Start-Sleep -Seconds 3
  $health = docker inspect -f '{{.State.Health.Status}}' cicd-gitea
} until ($health -eq 'healthy' -or (Get-Date) -gt $deadline)
if ($health -ne 'healthy') { throw "Gitea no respondio a tiempo (estado: $health)" }

# ---------------------------------------------------------------------------
Step "Usuario admin '$($cfg.GITEA_ADMIN_USER)'"
$users = docker compose exec -T -u git gitea gitea admin user list --admin
if (-not ($users -match "\s$([regex]::Escape($cfg.GITEA_ADMIN_USER))\s")) {
  docker compose exec -T -u git gitea gitea admin user create --admin `
    --username $cfg.GITEA_ADMIN_USER --password $cfg.GITEA_ADMIN_PASSWORD `
    --email $cfg.GITEA_ADMIN_EMAIL --must-change-password=false
  Check-Exit 'crear usuario admin'
} else { Write-Host 'Ya existe.' }

# ---------------------------------------------------------------------------
Step 'Runner de Gitea Actions'
if ([string]::IsNullOrWhiteSpace($cfg.RUNNER_TOKEN)) {
  $tokenOut = docker compose exec -T -u git gitea gitea actions generate-runner-token
  Check-Exit 'generar token del runner'
  $token = ($tokenOut | Where-Object { $_ -match '^\s*[A-Za-z0-9]{20,}\s*$' } | Select-Object -Last 1).Trim()
  if (-not $token) { throw "No se pudo leer el token: $tokenOut" }
  Set-DotEnvValue 'RUNNER_TOKEN' $token
  $cfg = Read-DotEnv
}
docker compose up -d runner
Check-Exit 'levantar runner'

if ($SkipImport) { Step 'Listo (sin importar proyecto)'; exit 0 }

# ---------------------------------------------------------------------------
$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($cfg.GITEA_ADMIN_USER):$($cfg.GITEA_ADMIN_PASSWORD)"))
$headers = @{ Authorization = $auth }
$repo = $cfg.REPO_NAME
$owner = $cfg.GITEA_ADMIN_USER

Step "Repo $owner/$repo en Gitea"
try {
  Invoke-RestMethod -Uri "$GiteaUrl/api/v1/repos/$owner/$repo" -Headers $headers | Out-Null
  Write-Host 'Ya existe.'
} catch {
  $body = @{ name = $repo; private = $false; default_branch = 'main'; description = 'API de productos - home lab CI/CD' } | ConvertTo-Json
  Invoke-RestMethod -Method Post -Uri "$GiteaUrl/api/v1/user/repos" -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
  Write-Host 'Creado.'
}

# ---------------------------------------------------------------------------
Step 'SonarQube: admin, proyecto, token y secreto SONAR_TOKEN en Gitea'
$deadline = (Get-Date).AddMinutes(6)
do {
  Start-Sleep -Seconds 5
  $sh = docker inspect -f '{{.State.Health.Status}}' cicd-sonarqube
} until ($sh -eq 'healthy' -or (Get-Date) -gt $deadline)
if ($sh -ne 'healthy') { throw "SonarQube no respondio a tiempo (estado: $sh)" }

function Sonar-Auth($user, $pass) { @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($user):$($pass)")) } }
$sonarHeaders = Sonar-Auth 'admin' $cfg.SONAR_ADMIN_PASSWORD
$valid = (Invoke-RestMethod -Uri "$SonarUrl/api/authentication/validate" -Headers $sonarHeaders).valid
if (-not $valid) {
  # Primera vez: el admin trae password admin/admin y hay que cambiarlo
  Invoke-RestMethod -Method Post -Uri "$SonarUrl/api/users/change_password" -Headers (Sonar-Auth 'admin' 'admin') `
    -Body @{ login = 'admin'; previousPassword = 'admin'; password = $cfg.SONAR_ADMIN_PASSWORD } | Out-Null
  Write-Host 'Password del admin de SonarQube actualizado.'
}

$proj = Invoke-RestMethod -Uri "$SonarUrl/api/projects/search?projects=productos-api" -Headers $sonarHeaders
if ($proj.paging.total -eq 0) {
  # production = rama principal; dev/QA/release como ramas y los PRs como pull requests
  Invoke-RestMethod -Method Post -Uri "$SonarUrl/api/projects/create" -Headers $sonarHeaders `
    -Body @{ project = 'productos-api'; name = 'productos-api'; mainBranch = 'production' } | Out-Null
  Write-Host 'Proyecto productos-api creado.'
}

if ([string]::IsNullOrWhiteSpace($cfg.SONAR_TOKEN)) {
  try { Invoke-RestMethod -Method Post -Uri "$SonarUrl/api/user_tokens/revoke" -Headers $sonarHeaders -Body @{ name = 'gitea-actions' } | Out-Null } catch {}
  $tok = Invoke-RestMethod -Method Post -Uri "$SonarUrl/api/user_tokens/generate" -Headers $sonarHeaders `
    -Body @{ name = 'gitea-actions'; type = 'GLOBAL_ANALYSIS_TOKEN' }
  Set-DotEnvValue 'SONAR_TOKEN' $tok.token
  $cfg = Read-DotEnv
  Write-Host 'Token de analisis generado.'
}
Invoke-RestMethod -Method Put -Uri "$GiteaUrl/api/v1/repos/$owner/$repo/actions/secrets/SONAR_TOKEN" -Headers $headers `
  -ContentType 'application/json' -Body (@{ data = $cfg.SONAR_TOKEN } | ConvertTo-Json) | Out-Null
Write-Host 'Secreto SONAR_TOKEN configurado en el repo.'

# ---------------------------------------------------------------------------
if (-not $SkipK8s) {
  Step 'Cluster Kubernetes (k3d): homelab'
  foreach ($tool in 'k3d', 'kubectl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
      throw "Falta $tool. Windows: winget install k3d.k3d / kubectl viene con Docker Desktop. Linux: ver README (seccion Kubernetes)."
    }
  }
  $clusters = @(k3d cluster list -o json | ConvertFrom-Json)
  if (-not ($clusters | Where-Object { $_.name -eq 'homelab' })) {
    k3d cluster create --config (Join-Path $PSScriptRoot 'k3d\cluster.yaml')
    Check-Exit 'k3d cluster create'
  } else {
    k3d cluster start homelab   # por si estaba detenido; si ya corre no hace nada
    Check-Exit 'k3d cluster start'
  }
  $kc = @('--context', 'k3d-homelab')
  kubectl @kc apply -k (Join-Path $PSScriptRoot 'k3d\platform')
  Check-Exit 'kubectl apply k3d/platform'

  # Kubeconfig de la ServiceAccount gitea-deployer (solo puede desplegar en dev/qa/release/production)
  $deadline = (Get-Date).AddMinutes(1)
  do {
    Start-Sleep -Seconds 2
    $saToken = kubectl @kc -n cicd-system get secret gitea-deployer-token -o 'jsonpath={.data.token}'
  } until ($saToken -or (Get-Date) -gt $deadline)
  if (-not $saToken) { throw 'Kubernetes no genero el token de gitea-deployer' }
  $caData = kubectl @kc -n cicd-system get secret gitea-deployer-token -o 'jsonpath={.data.ca\.crt}'
  $saToken = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($saToken))
  $kubeconfig = @"
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: https://k3d-homelab-serverlb:6443
      certificate-authority-data: $caData
users:
  - name: gitea-deployer
    user:
      token: $saToken
contexts:
  - name: homelab
    context:
      cluster: homelab
      user: gitea-deployer
current-context: homelab
"@
  $kubeconfigB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($kubeconfig))
  Invoke-RestMethod -Method Put -Uri "$GiteaUrl/api/v1/repos/$owner/$repo/actions/secrets/KUBECONFIG" -Headers $headers `
    -ContentType 'application/json' -Body (@{ data = $kubeconfigB64 } | ConvertTo-Json) | Out-Null
  Write-Host 'Secreto KUBECONFIG configurado en el repo.'
}

# ---------------------------------------------------------------------------
Step 'Preparando copia de trabajo en .\workspace (tu repo original no se toca)'
$ws = Join-Path $PSScriptRoot "workspace\$repo"
if (-not (Test-Path $ws)) {
  git clone --quiet --branch main --single-branch $cfg.SOURCE_REPO $ws
  Check-Exit 'git clone del proyecto origen'
  git -C $ws remote remove origin
}
# Las plantillas de CI siempre se versionan en main
git -C $ws switch --quiet main
Check-Exit 'git switch main en la copia de trabajo (tiene cambios sin commit?)'
Copy-Item (Join-Path $PSScriptRoot 'templates\Dockerfile')     $ws -Force
Copy-Item (Join-Path $PSScriptRoot 'templates\.dockerignore')  $ws -Force
Copy-Item (Join-Path $PSScriptRoot 'templates\.gitattributes') $ws -Force
Copy-Item (Join-Path $PSScriptRoot 'templates\.gitea') $ws -Recurse -Force   # workflows + scripts
Copy-Item (Join-Path $PSScriptRoot 'templates\k8s') $ws -Recurse -Force     # manifiestos (kustomize)

git -C $ws add -A
git -C $ws diff --cached --quiet
if ($LASTEXITCODE -ne 0) {
  git -C $ws commit --quiet -m 'ci: Dockerfile y workflow de Gitea Actions para build + push al registry'
  Check-Exit 'git commit'
}

# ---------------------------------------------------------------------------
Step 'Push de main y ramas dev, QA, release, production'
$pushUrl = "http://$($owner):$($cfg.GITEA_ADMIN_PASSWORD)@localhost:$($cfg.GITEA_HTTP_PORT)/$owner/$repo.git"
# main (no protegida) siempre recibe la ultima version de las plantillas.
# Las ramas de ambiente solo se crean si no existen: si ya tienen historial (merges) no se tocan;
# los cambios de CI les llegan por PR (main -> dev -> QA -> ...).
git -C $ws -c credential.helper= push --quiet $pushUrl main:main
Check-Exit 'git push main'
$remoteHeads = git -C $ws -c credential.helper= ls-remote --heads $pushUrl
foreach ($b in 'dev', 'QA', 'release', 'production') {
  if ($remoteHeads -match "refs/heads/$b$") { Write-Host "$b ya existe, no se modifica."; continue }
  git -C $ws -c credential.helper= push --quiet $pushUrl "main:refs/heads/$b"
  Check-Exit "git push $b"
}

# ---------------------------------------------------------------------------
Step 'Proteccion de ramas dev, QA, release, production'
# - Solo se integra por PR (push directo bloqueado, salvo el admin para el bootstrap)
# - Los checks version-check y build-and-push deben estar en verde para poder hacer merge
# - Ni el admin puede saltarse los checks al mergear
$protection = @{
  enable_push                  = $true
  enable_push_whitelist        = $true
  push_whitelist_usernames     = @($owner)
  enable_status_check          = $true
  status_check_contexts        = @(
    'pr-validation / version-check (pull_request)',
    'docker-build / build-and-push (pull_request)',
    'security / gitleaks (pull_request)',
    'security / trivy-fs (pull_request)',
    'security / sonarqube (pull_request)'
  )
  block_on_outdated_branch     = $true
  block_on_rejected_reviews    = $true
  block_admin_merge_override   = $true
  required_approvals           = 0
}
foreach ($b in 'dev', 'QA', 'release', 'production') {
  $protection.rule_name = $b
  $json = $protection | ConvertTo-Json
  try {
    Invoke-RestMethod -Uri "$GiteaUrl/api/v1/repos/$owner/$repo/branch_protections/$b" -Headers $headers | Out-Null
    Invoke-RestMethod -Method Patch -Uri "$GiteaUrl/api/v1/repos/$owner/$repo/branch_protections/$b" -Headers $headers -ContentType 'application/json' -Body $json | Out-Null
    Write-Host "$b : actualizada"
  } catch {
    Invoke-RestMethod -Method Post -Uri "$GiteaUrl/api/v1/repos/$owner/$repo/branch_protections" -Headers $headers -ContentType 'application/json' -Body $json | Out-Null
    Write-Host "$b : creada"
  }
}

# Remote sin credenciales para que trabajes desde la copia
if (-not ((git -C $ws remote) -contains 'gitea')) {
  git -C $ws remote add gitea "$GiteaUrl/$owner/$repo.git"
}

Step 'Listo'
Write-Host "Gitea          : $GiteaUrl   (usuario/password en .env)"
Write-Host "Actions        : $GiteaUrl/$owner/$repo/actions"
Write-Host "SonarQube      : $SonarUrl   (usuario admin, password SONAR_ADMIN_PASSWORD en .env)"
Write-Host "Registry UI    : http://localhost:$($cfg.REGISTRY_UI_PORT)"
Write-Host "Registry API   : http://localhost:$($cfg.REGISTRY_PORT)/v2/_catalog"
if (-not $SkipK8s) {
  Write-Host "Kubernetes     : kubectl --context k3d-homelab get pods -A"
  Write-Host "App por ambiente: http://productos-<dev|qa|release|production>.localhost:8081/api/productos"
}
Write-Host "Copia de trabajo: $ws"
