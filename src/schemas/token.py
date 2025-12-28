from pydantic import BaseModel
from datetime import datetime
from typing import Optional
from uuid import UUID


class Token(BaseModel):
        
    token: str
    expires_at: datetime
    
    
class DecodedRefreshToken(BaseModel):
    
    token_id: str
    
    
class DecodedAccessToken(BaseModel):
    
    user_id: UUID
    tenant_id: UUID    


class RefreshToken(BaseModel):
    
    id: UUID
    user_id: UUID
    family_id: Optional[UUID]
    expires_at: datetime
    created_at: datetime
    revoked: bool
    replaced_by: Optional[UUID]
    
    
class AccessTokenCreate(BaseModel):
    
    jwt_token: str
    expires_at: datetime
    

class RefreshTokenCreate(BaseModel):
    
    user_id: UUID
    token_id: UUID
    family_id: UUID
    expires_at: datetime
    revoked: bool
    replaced_by: Optional[UUID]
    jwt_token: str
    
    

class SessionToken(BaseModel):
    
    access_token: str
    access_token_expires_at: datetime
    
    refresh_token: str
    refresh_token_expires_at: datetime
    