from pydantic import BaseModel, Field, ConfigDict
from typing import Optional
from decimal import Decimal
from uuid import UUID


class SaleItemBase(BaseModel):
    
    quantity: Decimal = Field(
        ..., 
        gt=0,
        decimal_places=3,
        description="Quantidade vendida (deve ser maior que zero)"
    )    
    unit_sale_price: Decimal = Field(
        ..., 
        ge=0, 
        decimal_places=2,
        description="Preço unitário cobrado nesta venda (pode diferir do cadastro se houver desconto pontual)"
    )


class SaleItemCreate(BaseModel):
    
    sale_id: UUID = Field(..., description="ID da venda a qual o item pertence")
    product_id: UUID = Field(..., description="Produto sendo vendido")
    quantity: Decimal = Field(..., gt=0, decimal_places=3)    
    unit_sale_price: Decimal = Field(..., ge=0, decimal_places=2)
    

class SaleItemUpdate(BaseModel):

    quantity: Optional[Decimal] = Field(default=None, gt=0, decimal_places=3)
    unit_sale_price: Optional[Decimal] = Field(default=None, ge=0, decimal_places=2)


class SaleItemResponse(SaleItemBase):
    
    id: UUID
    sale_id: UUID
    product_id: UUID
    # (Visível apenas para Admin/Gerente
    unit_cost_price: Optional[Decimal]    
    subtotal: Decimal    
    model_config = ConfigDict(from_attributes=True)