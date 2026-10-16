"""Constants for OpenPlate."""

DOMAIN = "openplate"
PLATFORMS = ["binary_sensor", "event", "sensor"]

CONF_DEVICE_ID = "device_id"
CONF_SECRET = "secret"
CONF_PLATES = "plates"
CONF_ABSENCE_TIMEOUT = "absence_timeout"
CONF_WEBHOOK_ID = "webhook_id"

DEFAULT_ABSENCE_TIMEOUT = 30
MAX_BODY_BYTES = 16 * 1024
SIGNATURE_MAX_AGE_SECONDS = 90
