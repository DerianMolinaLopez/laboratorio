# Build multi-stage de productos-api (Spring Boot / Java 17)

# ---- Etapa 1: compilar y ejecutar tests ----
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -ntp dependency:go-offline
COPY src ./src
RUN mvn -B -ntp package

# ---- Etapa 2: imagen final liviana ----
FROM eclipse-temurin:17-jre
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="productos-api" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}"
WORKDIR /app
# Parches de seguridad del SO base (Trivy bloquea el push si quedan HIGH/CRITICAL con fix)
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -r -u 10001 app
COPY --from=build /src/target/*.jar /app/app.jar
USER app
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
