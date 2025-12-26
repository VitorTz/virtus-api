from src.schemas.token import AccessTokenCreate, RefreshTokenCreate, DecodedRefreshToken, DecodedAccessToken
from src.schemas.rls import RLSConnection, AdminConnectionWithUser
from src.schemas.user import UserResponse
from fastapi import Depends, HTTPException, status, Cookie, Response
from datetime import datetime, timedelta, timezone
from src.constants import Constants
from passlib.context import CryptContext
from src.exceptions import DatabaseError
from typing import Optional
from asyncpg import Pool
from src.model import user as user_model
from src.db.db import get_db_pool
from src import util
import hashlib
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
    

def create_access_token(user_id: uuid.UUID | str) -> AccessTokenCreate:
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=Constants.ACCESS_TOKEN_EXPIRE_MINUTES)
    
    payload = {
        "sub": str(user_id),
        "type": "access",
        "exp": expires_at
    }
    
    jwt_token = jwt.encode(
        payload,
        Constants.SECRET_KEY,
        algorithm=Constants.ALGORITHM
    )
    
    return AccessTokenCreate(
        jwt_token=jwt_token,
        expires_at=expires_at
    )


def create_refresh_token(
    user_id: uuid.UUID,
    family_id: Optional[uuid.UUID] = None  
) -> RefreshTokenCreate:
    token_id = uuid.uuid4()
    expires_at = datetime.now(timezone.utc) + timedelta(days=Constants.REFRESH_TOKEN_EXPIRE_DAYS)
    
    payload = {
        "sub": str(token_id),
        "exp": expires_at,
        "type": "refresh"
    }
    
    jwt_token: str = jwt.encode(
        payload,
        Constants.SECRET_KEY,
        algorithm=Constants.ALGORITHM
    )
    
    return RefreshTokenCreate(
        user_id=user_id,
        token_id=token_id,
        expires_at=expires_at,
        family_id=uuid.uuid4() if not family_id else family_id,
        revoked=False,
        replaced_by=None,
        jwt_token=jwt_token
    )


def decode_access_token(access_token: str) -> DecodedAccessToken:
    if not access_token:
        raise CREDENTIALS_EXCEPTION
        
    try:
        jwt_payload = jwt.decode(
            access_token,
            Constants.SECRET_KEY,
            algorithms=[Constants.ALGORITHM]
        )
        
        if jwt_payload.get("type") != "access":
            raise CREDENTIALS_EXCEPTION

        user_id = jwt_payload.get("sub")        
        
        return DecodedAccessToken(user_id=user_id)
        
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
        
        token_id = jwt_payload.get("sub")
        
        if jwt_payload.get("type") != "refresh" or not token_id:
            raise CREDENTIALS_EXCEPTION        
        
        return DecodedRefreshToken(token_id=token_id)
    except Exception:
        raise CREDENTIALS_EXCEPTION
    

async def extract_user( 
    pool: Pool = Depends(get_db_pool),
    access_token: Optional[str] = Cookie(default=None)
):
    user_data: DecodedAccessToken = decode_access_token(access_token)
    async with pool.acquire() as connection:        
        async with connection.transaction():
            user: Optional[UserResponse] = await user_model.get_user_by_id(user_data.user_id, connection)
            yield AdminConnectionWithUser(user=user, conn=connection)
            

async def get_rls_connection(
    pool: Pool = Depends(get_db_pool),
    access_token: Optional[str] = Cookie(default=None)
):
    user_data: DecodedAccessToken = decode_access_token(access_token)    
    async with pool.acquire() as connection:
        async with connection.transaction():
            try:
                row = await user_model.get_user_rls_data(user_data.user_id, connection)
                if not row: raise CREDENTIALS_EXCEPTION
                await connection.execute("SET LOCAL ROLE app_runtime")
                await connection.execute(
                    """
                    SELECT set_config('app.current_user_id', $1::text, true),
                           set_config('app.current_user_roles', $2, true),
                           set_config('app.current_user_tenant_id', $3::text, true),
                           set_config('app.current_user_max_privilege', $4::text, true)
                    """,
                    str(row['id']),
                    "{" + ",".join(row['roles']) + "}",
                    str(row['tenant_id']),
                    str(row['max_privilege_level'])
                )
            except Exception as e:
                print(f"[CRITICAL] Erro ao configurar sessão RLS: {e}")
                raise DatabaseError(code=500, detail="Security context failure.")
            
            yield RLSConnection(row, connection)


async def get_postgres_connection(pool: Pool = Depends(get_db_pool)):
    async with pool.acquire() as connection:
        yield connection


def set_session_token_cookie(
    response: Response, 
    access_token_jwt: str,
    access_token_expires_at: datetime,
    refresh_token_jwt: str,
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
        value=access_token_jwt,
        httponly=True,
        secure=secure_policy,
        samesite=samesite_policy,
        path="/",
        max_age=util.seconds_until(access_token_expires_at)
    )
    
    # Cookie do Refresh Token (longa duração)
    response.set_cookie(
        key="refresh_token",
        value=refresh_token_jwt,
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
