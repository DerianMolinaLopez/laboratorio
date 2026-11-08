# Home Lab CI/CD con Gitea Actions + Docker Registry

Flujo DevOps local, todo en Docker y aislado de tu entorno:

```
 developer ──push/PR──► Gitea (:3000) ──job──► act_runner ──► Docker-in-Docker
                                                                 │ gitleaks · trivy-fs · sonarqube ──► SonarQube (:9000)
                                                                 │ docker build (mvn package + tests)
                                                                 │ trivy image (bloquea si HIGH/CRITICAL)
                                                                 ▼
                                                     Registry (:5000) ◄── Registry UI (:5080)
                                                                 │ deploy (solo en push/merge a una rama de ambiente)
                                                                 ▼
                                           k3d "homelab" (k3s) ── ns dev · qa · release · production
                                                                 └─► http://productos-<ambiente>.localhost:8081
```

| Servicio      | URL                                   | Para qué                                   |
|---------------|---------------------------------------|--------------------------------------------|
| Gitea         | http://localhost:3000                 | Repos, PRs y pestaña **Actions**           |
| SonarQube     | http://localhost:9000                 | Calidad, cobertura, Quality Gate por rama/PR (usuario `admin`, password `SONAR_ADMIN_PASSWORD` en `.env`) |
| Registry UI   | http://localhost:5080                 | Ver/borrar imágenes y tags                 |
| Registry API  | http://localhost:5000/v2/_catalog     | `docker pull localhost:5000/...`           |
| Git por SSH   | `ssh://git@localhost:2222/...`        | Opcional                                   |
| App en k8s    | http://productos-dev.localhost:8081/api/productos | Una URL por ambiente (`dev`, `qa`, `release`, `production`) |
| Kubernetes API| `kubectl --context k3d-homelab ...`   | Solo en `127.0.0.1:6550`                   |

## Por qué no afecta tu máquina

- Los jobs y los `docker build` corren en un **Docker-in-Docker** propio (`cicd-dind`), no en tu
  Docker Desktop: imágenes, capas y contenedores de CI quedan en el volumen `dind-data`.
- Todo usa **volúmenes con nombre** (nada se sincroniza con OneDrive).
- Tu repo original (`SOURCE_REPO`) **no se modifica**: el bootstrap clona una copia en `.\workspace`.
- El API del dind (2375) no se publica al host, solo existe en la red interna.

## Arranque

Con Docker Desktop abierto:

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

El script crea `.env` (con un password aleatorio para el admin de Gitea), levanta los servicios,
crea el admin, registra el runner, crea el repo `productos-api`, le agrega el `Dockerfile` y el
workflow y hace push de `main`, `dev`, `QA`, `release` y `production`. Ese push dispara los primeros builds.

Usuario y password de Gitea: `GITEA_ADMIN_USER` / `GITEA_ADMIN_PASSWORD` en `.env`.

## Flujo de ramas y tags de imagen

Workflow: `templates/.gitea/workflows/docker-build.yml` (en el repo queda en `.gitea/workflows/`).

| Evento                                    | Tags en `productos-api`                                        |
|-------------------------------------------|----------------------------------------------------------------|
| PR hacia `dev`/`QA`/`release`/`production`| `pr-<N>`, `pr-<N>-<sha>`                                       |
| push / merge a `dev`                      | `dev-<version>-<sha>`, `dev-latest`                            |
| push / merge a `QA`                       | `qa-<version>-<sha>`, `qa-latest`                              |
| push / merge a `release`                  | `release-<version>-<sha>`, `release-latest`, `rc-<version>`    |
| push / merge a `production`               | `production-<version>-<sha>`, `production-latest`, `<version>`, `latest` |

`<version>` sale del `pom.xml`. El build ejecuta `mvn package`, así que si los tests fallan
la imagen no se publica y el PR queda en rojo.

## Validación de versión en PRs

Workflow `templates/.gitea/workflows/pr-validation.yml` + script `templates/.gitea/scripts/check-version.sh`.

En todo PR hacia `dev`, `QA`, `release` o `production`, el job **version-check** compara la
`<version>` del `pom.xml` del PR contra la de la rama destino: debe ser **mayor**
(`1.0.0 -> 1.0.1` ✅, `1.0.0 -> 1.0.0` ❌, `1.1.0 -> 1.0.9` ❌). Si no, el PR queda en rojo.

## Seguridad y calidad (DevSecOps)

Workflow `templates/.gitea/workflows/security.yml` (en PRs y en push a las ramas de ambiente) más
un paso extra en `docker-build.yml`. Todas las herramientas corren como contenedores dentro del dind.

| Check | Herramienta | Qué revisa | Falla cuando |
|---|---|---|---|
| `security / gitleaks` | Gitleaks | Secretos en los commits (en PR: solo los commits nuevos) | Encuentra un secreto |
| `security / trivy-fs` | Trivy | CVEs en dependencias Maven + malas configuraciones (Dockerfile) | Hay HIGH/CRITICAL **con parche disponible** |
| `security / sonarqube` | SonarQube + JaCoCo | Bugs, vulnerabilidades, code smells, cobertura, duplicación | No pasa el Quality Gate (*Sonar way*) |
| `docker-build` (paso Trivy) | Trivy | La imagen final: SO base + jars dentro del `app.jar` | Hay HIGH/CRITICAL con parche → **no se publica** en el registry |

- SonarQube usa el plugin de la comunidad para ramas/PRs: `production` es la rama principal,
  `dev`/`QA`/`release` aparecen como ramas y cada PR se analiza aparte (solo el código nuevo).
- El token de análisis lo crea el bootstrap y se guarda como secreto `SONAR_TOKEN` del repo en Gitea.
- `--ignore-unfixed`: solo bloquea lo que se puede arreglar actualizando. Para aceptar un riesgo
  puntual, agrega el CVE a un archivo `.trivyignore` en el repo (con un comentario del porqué).
- Trivy lee las dependencias de una caché local de Maven (`m2-cache-trivy`, dentro del dind): si las
  pide una por una a Maven Central, este responde 429 (rate limit).

Primer caso real que detectó: Spring Boot 3.3.5 traía 41 vulnerabilidades HIGH/CRITICAL (Tomcat,
Spring Framework, Jackson, `apt` de la imagen base). Se resolvió en el PR #3 subiendo a Spring Boot
4.1.2 (algunos CVE críticos de Spring Framework solo tienen parche en la 7.x) y aplicando los
parches del SO en el `Dockerfile`.

## Protección de ramas

`bootstrap.ps1` aplica a `dev`, `QA`, `release` y `production` (vía API de Gitea):

| Regla | Efecto |
|---|---|
| Checks obligatorios | `version-check`, `build-and-push`, `gitleaks`, `trivy-fs` y `sonarqube` deben estar en verde para mergear |
| Sin override de admin | ni el admin puede forzar el merge de un PR en rojo |
| Rama desactualizada | si la rama destino avanzó, hay que actualizar el PR antes de mergear |
| Push directo bloqueado | solo se integra por PR; únicamente `GITEA_ADMIN_USER` puede hacer push (lo usa el bootstrap) |

Las reglas se ven y editan en Gitea: *repo → Settings → Branches*.
Para promover entre ambientes la versión debe subir en cada salto, igual que en `dev`.

## Probar el flujo como developer

```powershell
cd .\workspace\productos-api
git switch -c feature/hola gitea/dev    # o: git fetch gitea; git switch -c feature/hola gitea/dev
# ...cambios...
git commit -am "feat: hola"
git push gitea feature/hola
```

Luego abre un PR `feature/hola -> dev` en Gitea: se construye `pr-<N>`. Al hacer merge se construye
`dev-...`. Promoción: PR `dev -> QA`, `QA -> release`, `release -> production`.

## Kubernetes (k3d)

El cluster `homelab` es **k3s corriendo en contenedores Docker** (vía [k3d](https://k3d.io)): 1 server
y 2 agents conectados a la red `homelab-cicd`, así que descargan imágenes de `registry:5000` y los
pipelines llegan a su API. Funciona igual en Windows (Docker Desktop) y en Linux (Docker Engine).

| Archivo | Qué hace |
|---|---|
| `k3d/cluster.yaml` | Definición del cluster: versión de k3s, nodos, puertos, registry inseguro |
| `k3d/platform/` | Namespaces `dev`, `qa`, `release`, `production` + ServiceAccount `gitea-deployer` (rol `edit` solo en esos namespaces) |
| `templates/k8s/base/` | Deployment, Service e Ingress de la app (no root, FS de solo lectura, probes, límites) |
| `templates/k8s/overlays/<ambiente>/` | Namespace, réplicas (1 en dev/qa, 2 en release/production), host del Ingress y tag de imagen |

Flujo del job **deploy** (en `docker-build.yml`, después de `build-and-push`, solo en push/merge):

1. Aplica `k8s/overlays/<ambiente>` con la imagen recién publicada (`<ambiente>-<version>-<sha>`).
2. Espera el rollout (máx. 3 min).
3. Smoke test: `GET /api/productos` a través del Ingress.
4. Si falla el rollout o el smoke test: `kubectl rollout undo` y el job queda en rojo.

El bootstrap guarda en Gitea el secreto `KUBECONFIG` con el token de `gitea-deployer`: el pipeline
no usa el admin del cluster.

```powershell
kubectl --context k3d-homelab get pods -A                       # todo el cluster
kubectl --context k3d-homelab -n dev rollout history deploy/productos-api   # historial de deploys
k3d cluster stop homelab                                         # apagar (conserva estado)
k3d cluster start homelab                                        # encender
k3d cluster delete homelab                                       # borrar solo el cluster
```

### Instalar k3d y kubectl

- **Windows**: `winget install k3d.k3d` (kubectl ya viene con Docker Desktop).
- **Linux**:
  ```bash
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG=v5.9.0 bash
  curl -LO "https://dl.k8s.io/release/v1.36.6/bin/linux/$(dpkg --print-architecture)/kubectl" && sudo install kubectl /usr/local/bin/
  ```

Para levantar el lab sin cluster: `bootstrap.ps1 -SkipK8s`.

## Usar las imágenes

```powershell
docker run --rm -p 8080:8080 localhost:5000/productos-api:dev-latest
```

> Dentro de los pipelines el registry se llama `registry:5000`; desde tu máquina es `localhost:5000`.
> Es el mismo registry. Hacer `pull` sí descarga la imagen a tu Docker Desktop; es opcional.

## Operación

```powershell
docker compose ps                     # estado
docker compose logs -f runner         # logs del runner
docker compose stop                   # apagar (conserva datos)
docker compose up -d                  # encender de nuevo
k3d cluster delete homelab            # (antes de down -v: el cluster usa la red del compose)
docker compose down -v; Remove-Item -Recurse -Force .\workspace, .\.env   # borrar TODO
```

## Estructura

```
cicd/
├── docker-compose.yml        # gitea, dind, runner, registry, registry-ui
├── runner/config.yaml        # config de act_runner (labels, red, DOCKER_HOST)
├── k3d/
│   ├── cluster.yaml          # cluster k3s "homelab" (nodos, puertos, registry)
│   └── platform/             # namespaces por ambiente + ServiceAccount del pipeline
├── templates/                # lo que se agrega al repo de la app
│   ├── Dockerfile
│   ├── k8s/base/             # Deployment, Service, Ingress
│   ├── k8s/overlays/         # dev, qa, release, production
│   ├── .dockerignore
│   ├── .gitattributes
│   └── .gitea/
│       ├── workflows/docker-build.yml
│       ├── workflows/pr-validation.yml
│       ├── workflows/security.yml
│       └── scripts/check-version.sh
├── bootstrap.ps1             # levanta y configura todo (idempotente)
├── .env.example              # puertos, versiones, admin, repo origen
└── workspace/                # (generado) copia de trabajo del repo
```

## Notas

- La primera ejecución tarda: descarga `catthehacker/ubuntu:act-22.04` (imagen de los jobs) y las
  dependencias de Maven dentro del dind. Las siguientes reutilizan la caché de capas.
- Gitea usa `.gitea/workflows/` y, si existe, ignora `.github/workflows/`; por eso el
  `pr-validation.yml` original de GitHub no corre aquí.
- Las actions (`actions/checkout@v4`) se descargan de github.com, así que se necesita internet.
