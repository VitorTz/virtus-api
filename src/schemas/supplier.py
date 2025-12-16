from pydantic import BaseModel, Field, ConfigDict, field_validator
from datetime import datetime
from typing import Optional
from uuid import UUID
import re


class SupplierBase(BaseModel):
    name: str = Field(
        ..., 
        description="Nome ou Razão Social do fornecedor"
    )
        
    cnpj: Optional[str] = Field(
        default=None, 
        max_length=20, 
        description="CNPJ do fornecedor. Deve ser único no sistema."
    )
        
    phone: Optional[str] = Field(
        default=None,
        description="Telefone (apenas números). Ex: 48999998888"
    )
    
    contact_name: Optional[str] = Field(
        default=None,
        description="Nome da pessoa de contato no fornecedor"
    )
    
    address: Optional[str] = Field(default=None)

    
    @field_validator('phone')
    @classmethod
    def clean_phone(cls, v: str | None) -> str | None:
        if v is None: return v
        numeric_phone = re.sub(r'\D', '', v)        
        return numeric_phone
    
    @field_validator('cnpj')
    @classmethod
    def clean_cnpj(cls, v: str | None) -> str | None:
        if v is None: return v
        return re.sub(r'[./-]', '', v)



class SupplierCreate(SupplierBase):
    
    pass

class SupplierUpdate(BaseModel):

    name: Optional[str] = None
    cnpj: Optional[str] = Field(default=None, max_length=20)
    phone: Optional[str] = None
    contact_name: Optional[str] = None
    address: Optional[str] = None    
    
    @field_validator('phone')
    @classmethod
    def clean_phone(cls, v: str | None) -> str | None:
        if v is None: return v
        numeric_phone = re.sub(r'\D', '', v)
        if len(numeric_phone) != 11:
            raise ValueError('O telefone deve conter exatamente 11 dígitos')
        return numeric_phone


class SupplierResponse(SupplierBase):
    
    id: UUID
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)