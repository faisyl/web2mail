FROM alpine:latest AS certs
RUN apk --no-cache add ca-certificates

FROM scratch
ARG TARGETPLATFORM
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY ${TARGETPLATFORM}/web2mail /web2mail
ENV BACKEND_TYPE=smtp
EXPOSE 8080
ENTRYPOINT ["/web2mail"]
