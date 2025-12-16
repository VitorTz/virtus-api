from pydantic import BaseModel, Field, ConfigDict
from typing import Optional
from datetime import datetime
from decimal import Decimal
from uuid import UUID


class PriceAuditBase(BaseModel):
    
    old_purchase_price: Optional[Decimal] = Field(
        default=None, 
        ge=0, 
        decimal_places=2,
        description="Preço de custo ANTES da alteração"
    )
    
    new_purchase_price: Optional[Decimal] = Field(
        default=None, 
        ge=0, 
        decimal_places=2,
        description="Novo preço de custo"
    )
    
    old_sale_price: Optional[Decimal] = Field(
        default=None, 
        ge=0, 
        decimal_places=2,
        description="Preço de venda ANTES da alteração"
    )
    
    new_sale_price: Optional[Decimal] = Field(
        default=None, 
        ge=0, 
        decimal_places=2,
        description="Novo preço de venda"
    )



class PriceAuditCreate(PriceAuditBase):
    
    product_id: UUID = Field(..., description="Produto que sofreu alteração")
    changed_by: Optional[UUID] = Field(
        default=None, 
        description="ID do usuário que fez a alteração (NULL se for sistema)"
    )


class PriceAuditResponse(PriceAuditBase):
    
    id: UUID
    product_id: UUID
    changed_by: Optional[UUID]
    changed_at: datetime

    model_config = ConfigDict(from_attributes=True)