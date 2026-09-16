# syntax=docker/dockerfile:1.7
ARG FLUTTER_IMAGE=docker.io/gmeligio/flutter-android:3.47.4
FROM ${FLUTTER_IMAGE} AS build

ARG SIGNBRIDGE_API_BASE_URL
WORKDIR /app
RUN flutter config --enable-web
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
RUN test -n "${SIGNBRIDGE_API_BASE_URL}" \
    && flutter build web --release \
      --dart-define=SIGNBRIDGE_API_BASE_URL="${SIGNBRIDGE_API_BASE_URL}"

FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html
EXPOSE 8080
