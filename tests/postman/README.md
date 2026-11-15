# Verificación integral del procesamiento PDF

Esta colección permite comprobar desde Postman el flujo asíncrono de un PDF: creación, carga directa a MinIO, extracción y descarga del texto.

## Preparación rápida

1. Inicie el stack desde `infra` con Compose y el perfil `full`.
2. Verifique que `api.localhost` y `s3.localhost` resuelvan localmente.
3. Configure TLS local con mkcert. En Postman, cargue el root CA de mkcert en **Settings → Certificates** o desactive **SSL certificate verification** solo para el entorno local.
4. Importe `pipeline-e2e.postman_collection.json` en Postman.
5. Abra las solicitudes de carga y vuelva a adjuntar el archivo indicado en su campo `file`. Las rutas locales no se conservan al importar una colección: use `fixtures/minimal.pdf` o `fixtures/not-a-pdf.txt`.

La solicitud de creación declara actualmente `size_bytes: 453`; si modifica el fixture, actualice ese valor con el tamaño exacto del archivo. Para la prueba de texto no PDF, ajuste a su vez el tamaño declarado al archivo correspondiente.

## Ejecución

- **Verificación básica**: ejecute ambas solicitudes para comprobar gateway y listado.
- **Recorrido correcto**: ejecute la carpeta completa en orden. La solicitud de estado se repite mientras el proceso no alcance estado terminal; después se solicita el enlace de descarga.
- **Casos negativos**: ejecute la carpeta completa en orden. Adjunte `not-a-pdf.txt` al segundo paso. La llamada de estado reintenta hasta 30 veces.
- **Límite de solicitudes**: ejecute la solicitud con 30 o más iteraciones en Collection Runner.
- Para ejecutar la colección con Newman, desde este directorio: `newman run pipeline-e2e.postman_collection.json --insecure --delay-request 2000`. Newman no puede adjuntar automáticamente los archivos de fixture desde las rutas importadas; configure los archivos de los campos `file` en el cliente Postman.

Los campos `form_fields` pueden incluir valores adicionales a los seis campos MinIO habituales de la colección. Si aparecen, añada cada campo como fila de texto antes de `file`, con el nombre de campo exacto y su variable `{{fm_<nombre>}}`. Los headers de firma se guardan como `hv_<nombre>`; agregue los requeridos por el servicio en la solicitud de carga.

## Resultados esperados

| Caso | Resultado esperado |
|---|---|
| Salud y listado | HTTP 200; listado con cuerpo JSON |
| Recorrido correcto | Creación 201, carga 2xx, estado `COMPLETED`, descarga 200 con `download_url` |
| Archivo no PDF | Carga aceptada por MinIO y estado terminal `REJECTED` con `failure_reason: NOT_A_PDF` |
| Idempotencia | Primera llamada 201; repetición 200 con el mismo `document_id` |
| Tamaño excesivo | HTTP 400 y `application/problem+json` |
| Descarga prematura | HTTP 409 y `application/problem+json` |
| Límite de solicitudes | Respuestas 200 o 429; en 429 se verifica una cabecera de espera/límite |

El caso `UPLOAD_EXPIRED` (documento nunca subido) depende del TTL del reconciliador y debe verificarse manualmente.

## Solución de problemas

- **403 Policy**: confirme que `file` sea el último campo multipart y que se hayan enviado todos los campos de la política.
- **409 al descargar**: el documento aún no está `COMPLETED`; continúe consultando su estado.
- **Errores TLS**: configure el CA de mkcert en Postman o desactive la verificación TLS únicamente en el entorno local.
- **429**: es esperable en ráfagas de más de 20 solicitudes; el gateway aplica `rate=10` y `burst=20`.
