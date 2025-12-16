from pydantic import BaseModel, Field, ConfigDict, field_validator
from typing import Optional
from datetime import datetime
from uuid import UUID


class UserAddressCreate(BaseModel):
    
    user_id: UUID
    
    number: Optional[str] = None
    descr: Optional[str] = None
    
    cep: str
    
    street: Optional[str] = Field(None, description="Logradouro (Rua, Av, etc)")
    complement: Optional[str] = Field(None, description="Complemento (Apto, Bloco)")
    unit: Optional[str] = None
    neighborhood: Optional[str] = None
    city: Optional[str] = None
    state_code: Optional[str] = Field(None, max_length=2, description="UF (ex: SP)")
    state: Optional[str] = None
    region: Optional[str] = None
    ibge_code: Optional[str] = None
    gia_code: Optional[str] = None
    area_code: Optional[str] = None
    siafi_code: Optional[str] = None
    

class AddressBase(BaseModel):
    
    street: Optional[str] = Field(None, description="Logradouro (Rua, Av, etc)")
    complement: Optional[str] = Field(None, description="Complemento (Apto, Bloco)")
    unit: Optional[str] = None
    neighborhood: Optional[str] = None
    city: Optional[str] = None
    state_code: Optional[str] = Field(None, max_length=2, description="UF (ex: SP)")
    state: Optional[str] = None
    region: Optional[str] = None
    ibge_code: Optional[str] = None
    gia_code: Optional[str] = None
    area_code: Optional[str] = None
    siafi_code: Optional[str] = None

class AddressCreate(AddressBase):
    
    cep: str = Field(..., description="CEP (Primary Key)")


class AddressResponse(AddressCreate):
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)

    @field_validator('cep')
    @classmethod
    def format_cep_output(cls, v: str) -> str:
        clean_cep = "".join(filter(str.isdigit, v))        
        if len(clean_cep) == 8: return f"{clean_cep[:5]}-{clean_cep[5:]}"            
        return v