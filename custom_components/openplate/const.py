"""Constants for OpenPlate."""

DOMAIN = "openplate"
PLATFORMS = ["binary_sensor", "event", "sensor"]

CONF_DEVICE_ID = "device_id"
CONF_SECRET = "secret"
CONF_PLATES = "plates"
CONF_ABSENCE_TIMEOUT = "absence_timeout"
CONF_WEBHOOK_ID = "webhook_id"
CONF_HOME_ASSISTANT_URL = "home_assistant_url"
CONF_RECOGNITION_URL = "recognition_url"
CONF_RECOGNITION_API_KEY = "recognition_api_key"
CONF_CAPTURE_INTERVAL = "capture_interval"

DEFAULT_ABSENCE_TIMEOUT = 30
DEFAULT_CAPTURE_INTERVAL = 1
MAX_BODY_BYTES = 16 * 1024
SIGNATURE_MAX_AGE_SECONDS = 90
PAIRING_CODE_LIFETIME_SECONDS = 10 * 60
PAIRING_WEBHOOK_ID = "openplate_pairing"
