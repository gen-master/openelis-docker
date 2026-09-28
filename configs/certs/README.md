# gcc-ca.pem

`Sectigo Public Server Authentication Root R46` — the CA that signs the `*.genetico.in` certificate
GCC presents at `services.genetico.in:8084`. Valid until 2038-01-18.

## Why this file exists

OpenELIS does not use the operating system's list of trusted certificate authorities.
`HttpClientConfig.sslContext()` calls:

    SSLContextBuilder.create()
        .loadKeyMaterial(keyStore, ...)
        .loadTrustMaterial(trustStore, trustStorePassword)   // no TrustStrategy
        .build();

`loadTrustMaterial` with no `TrustStrategy` makes that one file the *complete* set of trust anchors —
the public CA bundle is never consulted. And `tools/CertGeneration/genCert.sh` builds that file from
scratch with `keytool -import` of only OpenELIS's own self-signed ROOT_CA / intermediate / server
certs. There is no `cacerts` seeding anywhere in the image.

So an outbound call to GCC fails the TLS handshake even though GCC's certificate is publicly valid and
browsers accept it without complaint. The consequence is silent: `pollForRemoteTasks` throws, the
error is swallowed into the log, and no order is ever imported.

The CA is imported rather than the leaf certificate, so GCC's certificate renewals need no action here.

## Why the deploy step restarts the webapp

The `CloseableHttpClient` is a Spring `@Bean` — the trust store is read once, at context startup.
Importing into a running container changes nothing until the webapp restarts. Skipping the restart is
the failure mode that looks like "the certificate fix didn't work".

## Verifying it took effect

    docker exec openelisglobal-webapp keytool -list -alias gcc-ca \
      -storetype pkcs12 -keystore /etc/openelis-global/truststore -storepass "$SSL_TRUSTSTORE_PASSWORD"

and then, in the webapp log, an absence of `SSLHandshakeException` / `PKIX path building failed`
around the Task poll, which runs 10s after startup and every `remote.poll.frequency` ms after.
