from dotenv import load_dotenv
import os

load_dotenv()


class Constants:

    API_NAME = os.getenv("API_NAME")
    API_VERSION = os.getenv("API_VERSION")
    API_DESCR =  "API para gerenciamento de pequenos e médios comércios"

    IS_PRODUCTION = os.getenv("ENV", "DEV").lower().upper() == "PROD"

    REFRESH_TOKEN_EXPIRE_DAYS = int(os.getenv("REFRESH_TOKEN_EXPIRE_DAYS", 7))
    ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", 15))
    FERNET_KEY = os.getenv("FERNET_KEY")
    SECRET_KEY = os.getenv("SECRET_KEY")
    ALGORITHM = os.getenv("ALGORITHM")
    
    EXCHANGE_RATE_URL = f"https://api.exchangerate.host/live?access_key={os.getenv("EXCHANGE_RATE_API_KEY")}&currencies=USD,ARS,EUR,UYU,CLP,PYG&format=1&source=BRL"
    CURRENCY_UPDATE_TIME_IN_MINUTES = int(os.getenv("CURRENCY_UPDATE_TIME_IN_MINUTES", 481))
    
    NUVEM_FISCAL_API = os.getenv("NUVEM_FISCAL_TOKEN")

    MAX_BODY_SIZE = 20 * 1024 * 1024
    MAX_REQUESTS = 120 if os.getenv("ENV", "DEV") == "PROD" else 999_999_999
    WINDOW = 30

    PERMISSIONS_POLICY_HEADER = (
        "camera=(), "           # Bloqueia câmera (ajuste se usar scanner)
        "microphone=(), "       # Bloqueia microfone
        "geolocation=(), "      # Bloqueia geolocalização (ajuste se precisa)
        "payment=(self), "      # Permite pagamentos apenas no seu domínio
        "usb=(), "              # Bloqueia USB
        "interest-cohort=()"    # Bloqueia FLoC (privacidade)
    )
    
    MANAGEMENT_ROLES = ["ADMIN", "GERENTE", "FISCAL_CAIXA"]    
    SENSITIVE_PATHS = ["/auth/", "/admin/"]