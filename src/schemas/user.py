from pydantic import (
    BaseModel, 
    Field, 
    ConfigDict, 
    EmailStr, 
    field_validator
)
from typing import Optional, List
from datetime import datetime, date
from uuid import UUID
from enum import Enum
import re


class UserRoleEnum(str, Enum):
    """
    Espelhamento do ENUM 'user_role_enum' do PostgreSQL.
    Herda de 'str' para serialização JSON automática no FastAPI/Pydantic.
    """

    # --- Alto Nível / Administrativo ---
    ADMIN = 'ADMIN'              # Acesso total
    GERENTE = 'GERENTE'          # Gestão de equipe, anulações
    CONTADOR = 'CONTADOR'        # Relatórios fiscais e XMLs
    FINANCEIRO = 'FINANCEIRO'    # Contas a pagar/receber, DRE

    # --- Operacional Varejo ---
    CAIXA = 'CAIXA'              # Frente de loja (PDV)
    FISCAL_CAIXA = 'FISCAL_CAIXA'# Supervisor de PDV (cancelamentos/descontos)
    VENDEDOR = 'VENDEDOR'        # Pré-venda / Comissionado
    REPOSITOR = 'REPOSITOR'      # Conferência de gôndola/Preço
    ESTOQUISTA = 'ESTOQUISTA'    # Entrada de NF, inventário
    COMPRADOR = 'COMPRADOR'      # Ordens de compra

    # --- Operacional Gastronomia ---
    GARCOM = 'GARCOM'            # Pedidos Mobile/Mesas
    COZINHA = 'COZINHA'          # KDS / Produção
    BARMAN = 'BARMAN'            # Produção Bar
    ENTREGADOR = 'ENTREGADOR'    # Delivery

    # --- Acesso Externo ---
    CLIENTE = 'CLIENTE'          # App Fidelidade / Ecommerce
    
    
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
    
    roles: List[UserRoleEnum] = Field(
        default=[],
        description="Funções que o usuário acumula no sistema"
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
    
    roles: List[UserRoleEnum] = Field(
        ...,
        min_length=1,
        description="Funções que o usuário acumula no sistema"
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
    
    quick_access_pin_hash: Optional[str] = Field(
        default=None, 
        min_length=4,
        description="Senha de acesso rápdio, recomendado para garçons, caixa etc."
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
    
    id: UUID
    # --- Dados Pessoais (Dono pode alterar) ---
    name: Optional[str] = Field(None, min_length=2, max_length=256)
    nickname: Optional[str] = Field(None, max_length=256)
    birth_date: Optional[date] = None
    email: Optional[EmailStr] = None
    
    phone: Optional[str] = Field(None, pattern=r'^\d{10,11}$')
    cpf: Optional[str] = Field(None, pattern=r'^\d{11}$')
    image_url: Optional[str] = None

    # --- Segurança (Senhas vêm em texto plano e serão hasheadas no service) ---
    password: Optional[str] = Field(None, min_length=8, description="Nova senha de acesso web")
    quick_access_pin: Optional[str] = Field(None, min_length=4, max_length=8, pattern=r'^\d+$', description="PIN numérico para PDV")

    # --- Dados Fiscais/Profissionais (Apenas Gestão) ---
    state_tax_indicator: Optional[int] = Field(None, ge=1, le=9)
    loyalty_points: Optional[int] = Field(None, ge=0)
    commission_percentage: Optional[float] = Field(None, ge=0, le=100)
    
    is_active: Optional[bool] = None
    notes: Optional[str] = None
        
    roles: List[UserRoleEnum] = Field(
        ...,
        min_length=1,
        description="Funções que o usuário acumula no sistema"
    )

    @field_validator('phone', 'cpf', mode='before')
    @classmethod
    def sanitize_numeric_fields(cls, v: str | None) -> str | None:
        if v is None: return None
        if not isinstance(v, str) or not v.strip(): return None
        return re.sub(r'\D', '', v)
    

class UserResponse(UserBase):
    
    id: UUID    
    tenant_id: UUID
    created_at: datetime
    updated_at: datetime
    max_privilege_level: int
    created_by: Optional[UUID]
    model_config = ConfigDict(from_attributes=True)
    
    
class LoginData(UserResponse):
    
    password_hash: str
    

class UserCompleteResponse(BaseModel):
    
    model_config = ConfigDict(from_attributes=True) # Permite criar a partir de objetos do banco/ORM

    # --- Identificação ---
    id: UUID
    name: str
    nickname: Optional[str] = None
    image_url: Optional[str] = None
    
    # --- Dados Pessoais ---
    email: Optional[str] = None
    phone: Optional[str] = None
    cpf: Optional[str] = None
    birth_date: Optional[date] = None

    # --- Permissões e Segurança ---
    roles: List[str]
    max_privilege_level: int = 0
    is_active: bool

    # --- Dados Profissionais / Fiscais ---
    state_tax_indicator: int = 9
    loyalty_points: int = 0
    commission_percentage: float = 0.0
    
    notes: Optional[str] = None
    
    created_by: Optional[UUID] = None
    created_at: datetime
    updated_at: datetime
    
    @field_validator('cpf', mode='before')
    @classmethod
    def mask_cpf(cls, v: str | None) -> str | None:
        if v is None: return None

        clean_cpf = re.sub(r'\D', '', str(v))

        if len(clean_cpf) != 11: return v
        
        return f"***.{clean_cpf[3:6]}.***-**"
    
    
class UserManagementContext(BaseModel):
    
    model_config = ConfigDict(from_attributes=True)
    
    max_privilege_level: int
    has_management_permission: bool
    new_roles_max_privilege: int
    other_user_tenant_id: Optional[UUID] = None
    target_current_privilege_level: Optional[int] = 0
    