from pydantic import BaseModel, ConfigDict, EmailStr
from datetime import datetime
from typing import Optional
from uuid import UUID


class TenantPublicInfo(BaseModel):
    
    model_config = ConfigDict(from_attributes=True)
    
    id: UUID
    name: str
    slug: str
    created_at: datetime
    

class TenantCreate(BaseModel):
    
    tenant_name: str
    tenant_cnpj: Optional[str] = None
    tenant_notes: Optional[str] = None
    
    name: str
    email: EmailStr
    password: str
    cpf: str
    phone: Optional[str] = None