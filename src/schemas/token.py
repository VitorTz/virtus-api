from pydantic import BaseModel
from datetime import datetime
from typing import Optional
from uuid import UUID


class Token(BaseModel):
        
    token: str
    expires_at: datetime
    
    
class DecodedRefreshToken(BaseModel):
    
    token_hash: str
    family_id: Optional[UUID]
    
    
class DecodedAccessToken(BaseModel):
    
    user_id: UUID
    fgp: str


class RefreshToken(BaseModel):
    
    id: UUID    
    user_id: UUID
    token_hash: str
    device_hash: str
    family_id: Optional[UUID]
    expires_at: datetime
    created_at: datetime
    revoked: bool
    replaced_by: Optional[UUID]
    

class RefreshTokenCreate(BaseModel):
    
    user_id: UUID
    family_id: UUID
    token_hash: str
    device_hash: str
    expires_at: datetime
    revoked: bool
    replaced_by: Optional[UUID]
    
    

class SessionToken(BaseModel):
    
    access_token: str
    access_token_expires_at: datetime
    
    refresh_token: str
    refresh_token_expires_at: datetime
    