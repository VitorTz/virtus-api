from fastapi import Depends, HTTPException, status, Cookie, Response, Header
from datetime import datetime, timedelta, timezone
from src.schemas.token import Token, RefreshTokenCreate, DecodedRefreshToken, DecodedAccessToken
from src.schemas.rls import RLSConnection
from src.schemas.user import UserResponse
from src.constants import Constants
from passlib.context import CryptContext
from src.exceptions import DatabaseError
from cryptography.fernet import Fernet
from typing import Optional
from asyncpg import Pool
from src.model import user as user_model
from src.db.db import get_db_pool
from src import util
from typing import List, Any, AsyncGenerator
import secrets
import hashlib
import json
import uuid
import jwt


pwd_context = CryptContext(
    schemes=["argon2"],     
    deprecated="auto"
)


VALID_ROLES = {
    'ADMIN', 
    'CAIXA', 
    'GERENTE', 
    'CLIENTE', 
    'ESTOQUISTA', 
    'CONTADOR'
}

CREDENTIALS_EXCEPTION = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="Could not validate credentials",
    headers={"WWW-Authenticate": "Bearer"},
)

USER_IS_NOT_ACTIVE_EXCEPTION = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="User exists but is not active",
    headers={"WWW-Authenticate": "Bearer"},
)

INVALID_PASSWORD_EXCEPTION = HTTPException(
    status_code=status.HTTP_400_BAD_REQUEST,
    detail="Password must be at least 8 characters long"
)


def hash_password(password: str) -> str:
    if not password or len(password) < 8:
        raise INVALID_PASSWORD_EXCEPTION
    return pwd_context.hash(password)


def verify_password(plain_password: str, hashed_password: str) -> bool:    
    try:      
        return pwd_context.verify(plain_password, hashed_password)
    except Exception:
        return False
    

def sha256_encode(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def sha256_verify(value: str, encoded_value) -> str:
    return sha256_encode(value) == encoded_value


def create_access_token(
    user_id: uuid.UUID | str,
    client_fingerprint: str
) -> Token:
    fingerprint_hash = hashlib.sha256(client_fingerprint.encode()).hexdigest()
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=Constants.ACCESS_TOKEN_EXPIRE_MINUTES)
        
    sensitive_data = {
        "sub": str(user_id),
        "fgp": fingerprint_hash
    }
        
    fernet = Fernet(Constants.FERNET_KEY)
    encrypted_data = fernet.encrypt(json.dumps(sensitive_data).encode()).decode()
    
    payload = {
        "exp": expires_at,        
        "type": "access",
        "data": encrypted_data
    }
    
    token = jwt.encode(
        payload,
        Constants.SECRET_KEY,
        algorithm=Constants.ALGORITHM
    )
    
    return token, expires_at


def create_refresh_token(
    user_id: uuid.UUID, 
    device_fingerprint: str,
    family_id: Optional[uuid.UUID] = None    
) -> tuple[RefreshTokenCreate, str, datetime]:
    family_id = uuid.uuid4() if not family_id else family_id
    token_jti = secrets.token_urlsafe(64)
    token_hash = sha256_encode(token_jti)
    device_hash = sha256_encode(device_fingerprint)
    expires_at = datetime.now(timezone.utc) + timedelta(days=Constants.REFRESH_TOKEN_EXPIRE_DAYS)
    
    token_create = RefreshTokenCreate(
        user_id=user_id,
        token_hash=token_hash,
        device_hash=device_hash,
        expires_at=expires_at,
        family_id=family_id,
        revoked=False,
        replaced_by=None
    )
    
    if family_id:
        payload = {
            "jti": token_jti,
            "exp": expires_at,
            "family_id": str(family_id),
            "type": "refresh"        
        }
    else:
        payload = {
            "jti": token_jti,
            "exp": expires_at,            
            "type": "refresh"        
        }
    
    jwt_token: str = jwt.encode(
        payload,
        Constants.SECRET_KEY,
        algorithm=Constants.ALGORITHM
    )
    
    return token_create, jwt_token, expires_at


def decode_access_token(access_token: str, x_device_id: str) -> DecodedAccessToken:
    if not access_token or not x_device_id:
        raise CREDENTIALS_EXCEPTION
    
    try:
        jwt_payload = jwt.decode(
            access_token,
            Constants.SECRET_KEY,
            algorithms=[Constants.ALGORITHM]
        )
        
        # Validação básica do tipo
        if jwt_payload.get("type") != "access":
            raise CREDENTIALS_EXCEPTION

        # 2. Descriptografa o conteúdo sensível
        encrypted_data = jwt_payload.get("data")
        if not encrypted_data:
            raise CREDENTIALS_EXCEPTION
            
        # 3. Extrai os dados
        fernet = Fernet(Constants.FERNET_KEY)
        decrypted_json = fernet.decrypt(encrypted_data.encode()).decode()
        data = json.loads(decrypted_json)
        
        user_id = data.get("sub")
        fgp = data.get("fgp")
        
        
        if not sha256_verify(x_device_id, fgp) or not user_id:
            raise CREDENTIALS_EXCEPTION
        
        return DecodedAccessToken(
            user_id=user_id,
            fgp=fgp
        )
        
    except Exception:
        raise CREDENTIALS_EXCEPTION


def decode_refresh_token(refresh_token: Optional[str]) -> DecodedRefreshToken:    
    if not refresh_token: 
        raise CREDENTIALS_EXCEPTION
    
    try:
        jwt_payload = jwt.decode(
            refresh_token,
            Constants.SECRET_KEY,
            algorithms=[Constants.ALGORITHM]
        )
        
        token_jti = jwt_payload.get("jti")
        family_id = jwt_payload.get("family_id", None)
        
        if jwt_payload.get("type") != "refresh" or not token_jti:
            raise CREDENTIALS_EXCEPTION
        
        return DecodedRefreshToken(
            token_hash=sha256_encode(token_jti),
            family_id=family_id
        )
    except Exception:
        raise CREDENTIALS_EXCEPTION
    


async def get_rls_connection(
    pool: Pool = Depends(get_db_pool),
    access_token: Optional[str] = Cookie(default=None),
    x_device_id: str = Header(...)    
):
    user_data: DecodedAccessToken = decode_access_token(access_token, x_device_id)
    
    async with pool.acquire() as connection:        
        async with connection.transaction():
            try:
                user = await user_model.get_user_by_id(user_data.user_id, connection)                
                if not user: raise CREDENTIALS_EXCEPTION
                await connection.execute("SET LOCAL ROLE app_runtime")
                await connection.execute(
                    """
                    SELECT set_config('app.current_user_id', $1, true),
                           set_config('app.current_user_role', $2, true),
                           set_config('app.current_tenant_id', $3, true)
                    """,
                    str(user.id),
                    "{" + ",".join(user.roles) + "}",
                    str(user.tenant_id)
                )
                
            except Exception as e:
                print(f"[CRITICAL] Erro ao configurar sessão RLS: {e}")
                raise DatabaseError(code=500, detail="Security context failure.")
            
            yield RLSConnection(user, connection)


async def get_postgres_connection(pool: Pool = Depends(get_db_pool)):
    """
        Retorna uma conexão com o usuário postgres (super usuário)
    """    
    async with pool.acquire() as connection:
        async with connection.transaction():
            try:
                yield connection
            except Exception as e:
                raise e


def set_session_token_cookie(
    response: Response, 
    access_token: str,
    access_token_expires_at: datetime,
    refresh_token: str,
    refresh_token_expires_at: datetime
):
    if Constants.IS_PRODUCTION:
        samesite_policy = "none"
        secure_policy = True
    else:
        samesite_policy = "lax"
        secure_policy = False
    
    # Cookie do Access Token (curta duração)
    response.set_cookie(
        key="access_token",
        value=access_token,
        httponly=True,
        secure=secure_policy,
        samesite=samesite_policy,
        path="/",
        max_age=util.seconds_until(access_token_expires_at)
    )
    
    # Cookie do Refresh Token (longa duração)
    response.set_cookie(
        key="refresh_token",
        value=refresh_token,
        httponly=True,
        secure=secure_policy,
        samesite=samesite_policy,
        path="/",
        max_age=util.seconds_until(refresh_token_expires_at)
    )


def unset_session_token_cookie(response: Response):
    if Constants.IS_PRODUCTION:
        samesite_policy = "none"
        secure_policy = True
    else:
        samesite_policy = "lax"
        secure_policy = False

    response.delete_cookie(
        key="access_token",
        httponly=True,
        path="/",
        samesite=samesite_policy,
        secure=secure_policy
    )

    response.delete_cookie(
        key="refresh_token",
        httponly=True,
        path="/",
        samesite=samesite_policy,
        secure=secure_policy
    )
