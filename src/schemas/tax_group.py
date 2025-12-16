from pydantic import BaseModel, Field, ConfigDict
from typing import Optional
from decimal import Decimal
from uuid import UUID


class TaxGroupBase(BaseModel):
    description: str = Field(
        ..., 
        max_length=100,
        description="Descrição do grupo (ex: 'Bebidas Frias - Monofásico')"
    )
    
    icms_cst: str = Field(
        ..., 
        min_length=2, # Geralmente são 2 ou 3 dígitos (ex: 00, 10, 20, 101...)
        max_length=3,
        description="Código de Situação Tributária do ICMS (ex: 060 = cobrado anteriormente)"
    )
    
    pis_cofins_cst: str = Field(
        ..., 
        min_length=2,
        max_length=2,
        description="CST para PIS/COFINS (ex: 04 = Monofásico com alíquota zero)"
    )
        
    icms_rate: Decimal = Field(
        default=Decimal('0.00'), 
        ge=0, 
        lt=1000, 
        decimal_places=2,
        description="Alíquota do ICMS (%)"
    )
    
    pis_rate: Decimal = Field(
        default=Decimal('0.00'), 
        ge=0, 
        lt=1000, 
        decimal_places=2,
        description="Alíquota do PIS (%)"
    )
    
    cofins_rate: Decimal = Field(
        default=Decimal('0.00'), 
        ge=0, 
        lt=1000, 
        decimal_places=2,
        description="Alíquota do COFINS (%)"
    )

class TaxGroupCreate(TaxGroupBase):
    
    
    pass

class TaxGroupUpdate(BaseModel):
    
    description: Optional[str] = Field(default=None, max_length=100)
    icms_cst: Optional[str] = Field(default=None, max_length=3)
    pis_cofins_cst: Optional[str] = Field(default=None, max_length=2)
    icms_rate: Optional[Decimal] = Field(default=None, ge=0, lt=1000, decimal_places=2)
    pis_rate: Optional[Decimal] = Field(default=None, ge=0, lt=1000, decimal_places=2)
    cofins_rate: Optional[Decimal] = Field(default=None, ge=0, lt=1000, decimal_places=2)


class TaxGroupResponse(TaxGroupBase):
    id: UUID
    model_config = ConfigDict(from_attributes=True)