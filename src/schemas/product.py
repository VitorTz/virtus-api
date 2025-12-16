from pydantic import BaseModel, Field, ConfigDict, model_validator
from src.schemas.enums import MeasureUnit
from datetime import datetime
from typing import Optional
from decimal import Decimal
from uuid import UUID


class ProductBase(BaseModel):
    
    name: str = Field(
        ..., 
        description="Nome comercial do produto (único no sistema)"
    )
    
    sku: str = Field(
        ..., 
        min_length=2, 
        max_length=128,
        description="Código interno de identificação (Stock Keeping Unit)"
    )
    
    description: Optional[str] = Field(default=None, description="Descrição detalhada")
    
    category_id: int = Field(..., description="ID da categoria")
    
    image_url: Optional[str] = Field(default=None)
    
    
    gtin: Optional[str] = Field(default=None, max_length=14, description="EAN-13 ou similar")
    
    ncm: str = Field(
        default='00000000', 
        min_length=8, 
        max_length=8,
        description="Nomenclatura Comum do Mercosul"
    )
    
    cest: Optional[str] = Field(default=None, max_length=7, description="Código Especificador da Substituição Tributária")
    
    cfop_default: str = Field(default='5102', max_length=4, description="CFOP padrão")
    
    origin: str = Field(
        default='0', 
        min_length=1, 
        max_length=1, 
        description="Origem da mercadoria (0=Nacional, etc)"
    )
    
    tax_group_id: Optional[UUID] = Field(default=None, description="Grupo tributário vinculado")

    
    stock_quantity: Decimal = Field(default=Decimal('0.000'), decimal_places=3)
    min_stock_quantity: Decimal = Field(default=Decimal('0.000'), decimal_places=3)
    max_stock_quantity: Decimal = Field(default=Decimal('0.000'), decimal_places=3)
    average_weight: Decimal = Field(default=Decimal('0.0000'), decimal_places=4)
    purchase_price: Decimal = Field(default=Decimal('0.00'), decimal_places=2, ge=0)
    
    sale_price: Decimal = Field(default=Decimal('0.00'), decimal_places=2, ge=0)    
    measure_unit: MeasureUnit = Field(default=MeasureUnit.UN) 
    
    is_active: bool = Field(default=True, description="Se False, produto indisponível")
    needs_preparation: bool = Field(default=False, description="True para receitas (ex: lanches)")


class ProductCreate(ProductBase):
    
    @model_validator(mode='after')
    def check_profit_logic(self):
        # Replica a constraint do banco: sale_price >= purchase_price
        if self.sale_price < self.purchase_price:
            raise ValueError('O valor de venda não pode ser menor que o valor de compra.')
        return self

class ProductUpdate(BaseModel):
   

    name: Optional[str] = None
    sku: Optional[str] = Field(default=None, min_length=2, max_length=128)
    description: Optional[str] = None
    category_id: Optional[int] = None
    image_url: Optional[str] = None
    
    gtin: Optional[str] = Field(default=None, max_length=14)
    ncm: Optional[str] = Field(default=None, min_length=8, max_length=8)
    cest: Optional[str] = Field(default=None, max_length=7)
    cfop_default: Optional[str] = Field(default=None, max_length=4)
    origin: Optional[str] = Field(default=None, min_length=1, max_length=1)
    tax_group_id: Optional[UUID] = None

    stock_quantity: Optional[Decimal] = None
    min_stock_quantity: Optional[Decimal] = None
    max_stock_quantity: Optional[Decimal] = None
    average_weight: Optional[Decimal] = None
    
    purchase_price: Optional[Decimal] = Field(default=None, ge=0)
    sale_price: Optional[Decimal] = Field(default=None, ge=0)
    
    measure_unit: Optional[MeasureUnit] = None
    is_active: Optional[bool] = None
    needs_preparation: Optional[bool] = None

    @model_validator(mode='after')
    def check_profit_logic(self):
        # Validação complexa no Update:
        # Se o usuário enviar AMBOS, validamos.
        # Se enviar apenas um, não conseguimos validar 100% aqui sem consultar o banco,
        # então validamos apenas se ambos estiverem presentes no payload.
        if self.sale_price is not None and self.purchase_price is not None:
            if self.sale_price < self.purchase_price:
                raise ValueError('O valor de venda não pode ser menor que o valor de compra.')
        return self


class ProductResponse(ProductBase):

    id: UUID    
    profit_margin: Decimal 
    created_at: datetime
    updated_at: datetime
    model_config = ConfigDict(from_attributes=True)