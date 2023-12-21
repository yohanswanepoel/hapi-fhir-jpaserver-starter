FROM docker.io/library/maven:3.9.4-eclipse-temurin-17 AS build-hapi
WORKDIR /tmp/hapi-fhir-jpaserver-starter

ARG OPENTELEMETRY_JAVA_AGENT_VERSION=1.31.0
RUN curl -LSsO https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OPENTELEMETRY_JAVA_AGENT_VERSION}/opentelemetry-javaagent.jar

COPY pom.xml .
COPY server.xml .
# RUN mvn -ntp dependency:go-offline

COPY src/ /tmp/hapi-fhir-jpaserver-starter/src/
RUN mvn clean install -DskipTests -Djdk.lang.Process.launchMechanism=vfork

FROM build-hapi AS build-distroless
RUN mvn package -DskipTests spring-boot:repackage -Pboot
RUN mkdir /app && cp /tmp/hapi-fhir-jpaserver-starter/target/ROOT.war /app/main.war

########### bitnami tomcat version is suitable for debugging and comes with a shell
########### it can be built using eg. `docker build --target tomcat .`
FROM bitnami/tomcat:9.0 AS tomcat

RUN rm -rf /opt/bitnami/tomcat/webapps/ROOT && \
    mkdir -p /opt/bitnami/hapi/data/hapi/lucenefiles && \
    chmod 775 /opt/bitnami/hapi/data/hapi/lucenefiles

USER root
RUN mkdir -p /target && chown -R 1001:0 target
RUN chown -R 0 /target && \
    chmod -R g=u /target
USER 1001

COPY catalina.properties /opt/bitnami/tomcat/conf/catalina.properties
RUN chown -R 0 /opt/bitnami/tomcat/conf/catalina.properties && \
    chmod -R g=u /opt/bitnami/tomcat/conf/catalina.properties
COPY server.xml /opt/bitnami/tomcat/conf/server.xml
RUN chown -R 0 /opt/bitnami/tomcat/conf/server.xml && \
    chmod -R g=u /opt/bitnami/tomcat/conf/server.xml
COPY --from=build-hapi --chown=1001:0 /tmp/hapi-fhir-jpaserver-starter/target/ROOT.war /opt/bitnami/tomcat/webapps/ROOT.war
COPY --from=build-hapi --chown=1001:0 /tmp/hapi-fhir-jpaserver-starter/opentelemetry-javaagent.jar /app

ENV ALLOW_EMPTY_PASSWORD=yes

########### distroless brings focus on security and runs on plain spring boot - this is the default image
FROM registry.access.redhat.com/ubi9/openjdk-17:1.17-1 AS default
# 65532 is the nonroot user's uid
# used here instead of the name to allow Kubernetes to easily detect that the container
# is running as a non-root (uid != 0) user.
USER 1001
WORKDIR /app
RUN chown 1001:0 /app && chmod 775 /app

COPY --from=build-distroless --chown=1001:0 /app /app
COPY --from=build-hapi --chown=1001:0 /tmp/hapi-fhir-jpaserver-starter/opentelemetry-javaagent.jar /app

ENTRYPOINT ["java", "--class-path", "/app/main.war", "-Dloader.path=main.war!/WEB-INF/classes/,main.war!/WEB-INF/,/app/extra-classes", "org.springframework.boot.loader.PropertiesLauncher"]

# podman build -t hapi-js .
# podman run -p 9080:8080 hapi-js