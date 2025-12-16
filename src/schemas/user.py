from pydantic import (
    BaseModel, 
    Field, 
    ConfigDict, 
    EmailStr, 
    field_validator
)
from src.schemas.enums import UserRole
from typing import Optional, List
from datetime import datetime
from decimal import Decimal
from uuid import UUID
import re


class UserPayload(BaseModel):
    
    user_id: UUID
    tenant_id: UUID
    roles: str
    

class UserBase(BaseModel):
    
    tenant_id: UUID
    name: str = Field(
        ..., 
        min_length=2, 
        max_length=256,
        description="Nome completo do usuário"
    )
    
    nickname: Optional[str] = Field(
        default=None, 
        min_length=2, 
        max_length=256,
        description="Apelido ou nome social"
    )
        
    email: Optional[EmailStr] = Field(default=None, description="Email único")    
    
    notes: Optional[str] = Field(default=None, min_length=2, max_length=512)
    
    roles: List[str] = Field(
        default=[],
        description="Papeis que o usuário acumula no sistema"
    )
    
    
    state_tax_indicator: int = Field(
        default=9, 
        description="1=Contribuinte, 2=Isento, 9=Não Contribuinte"
    )


class UserCreate(BaseModel):
    
    name: str = Field(
        ..., 
        min_length=2, 
        max_length=256,
        description="Nome completo do usuário"
    )
    
    nickname: Optional[str] = Field(
        default=None, 
        min_length=2, 
        max_length=256,
        description="Apelido ou nome social"
    )
        
    email: Optional[EmailStr] = Field(default=None, description="Email único")    
    
    notes: Optional[str] = Field(default=None, min_length=2, max_length=512)
    
    roles: List[str] = Field(
        ...,
        description="Papeis que o usuário acumula no sistema"
    )
    
    state_tax_indicator: int = Field(
        default=9, 
        description="1=Contribuinte, 2=Isento, 9=Não Contribuinte"
    )
    
    password: Optional[str] = Field(
        default=None, 
        min_length=8, 
        description="Obrigatório para funcionários (Admin, Caixa, etc)"
    )
    
    phone: Optional[str] = Field(
        default=None,
        pattern=r'^\d{10,11}$', 
        description="Telefone (apenas números)"
    )
    
    cpf: Optional[str] = Field(
        default=None,
        pattern=r'^\d{11}$',
        description="CPF (apenas números)"
    )
        
    credit_limit: Decimal = Field(default=Decimal('0.00'), ge=0)
    
    @field_validator('phone', 'cpf', mode='before')
    @classmethod
    def sanitize_numeric_fields(cls, v: str | None) -> str | None:
        """
        Remove qualquer caractere que não seja dígito (pontos, traços, parênteses, espaços).
        Ex: '(48) 9999-9999' vira '4899999999'
        """
        if v is None: return None            
        if not v.strip(): return None        
        return re.sub(r'\D', '', v)   
    

class UserUpdate(BaseModel):
    
    name: Optional[str] = Field(default=None, min_length=2, max_length=256)
    nickname: Optional[str] = Field(default=None, min_length=2, max_length=256)
    email: Optional[EmailStr] = None
    notes: Optional[str] = Field(default=None, min_length=2, max_length=512)
    
    role: UserRole
    state_tax_indicator: int
    credit_limit: Optional[Decimal] = Field(..., ge=0)
    
    phone: Optional[str] = Field(
        default=None,
        pattern=r'^\d{10,11}$', 
        description="Telefone (apenas números)"
    )
    
    cpf: Optional[str] = Field(
        default=None,
        pattern=r'^\d{11}$',
        description="CPF (apenas números)"
    )
    
    @field_validator('phone', 'cpf', mode='before')
    @classmethod
    def sanitize_numeric_fields(cls, v: str | None) -> str | None:
        """
        Remove qualquer caractere que não seja dígito (pontos, traços, parênteses, espaços).
        Ex: '(48) 9999-9999' vira '4899999999'
        """
        if v is None: return None            
        if not v.strip(): return None        
        return re.sub(r'\D', '', v)


class UserResponse(UserBase):
    
    id: UUID    
    tenant_id: UUID
    credit_limit: Decimal
    invoice_amount: Decimal
    created_at: datetime
    updated_at: datetime
    created_by: Optional[UUID]
    model_config = ConfigDict(from_attributes=True)
    
    
class LoginData(UserResponse):
    
    password_hash: str