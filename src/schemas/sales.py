from pydantic import BaseModel, Field, ConfigDict, model_validator
from src.schemas.enums import SaleStatus
from typing import Optional
from datetime import datetime
from decimal import Decimal
from uuid import UUID


class SaleBase(BaseModel):

    
    status: SaleStatus = Field(
        default=SaleStatus.ABERTA, 
        description="Status atual da venda"
    )
    
    subtotal: Decimal = Field(
        default=Decimal('0.00'), 
        ge=0, 
        decimal_places=2,
        description="Soma bruta dos itens"
    )
    
    total_discount: Decimal = Field(
        default=Decimal('0.00'), 
        ge=0, 
        decimal_places=2,
        description="Desconto aplicado globalmente"
    )
    
    total_amount: Decimal = Field(
        default=Decimal('0.00'), 
        ge=0, 
        decimal_places=2,
        description="Valor final a pagar (Subtotal - Desconto)"
    )
    
    salesperson_id: Optional[UUID] = Field(
        default=None, 
        description="Funcionário que abriu a venda"
    )
    
    customer_id: Optional[UUID] = Field(
        default=None, 
        description="Cliente vinculado (opcional)"
    )

    
    @model_validator(mode='after')
    def validate_totals(self):
        calculated_total = self.subtotal - self.total_discount        
        if calculated_total < 0:
             raise ValueError("O desconto não pode ser maior que o subtotal.")
                     
        # O backend sempre irá ignorar o 'total_amount' enviado pelo cliente
        # Esta validação é feita apenas para consistência dos dados enviados pelo cliente
        if self.total_amount != calculated_total:
            raise ValueError(f"Inconsistência: Subtotal ({self.subtotal}) - Desconto ({self.total_discount}) != Total ({self.total_amount})")
        
        return self


class SaleCreate(BaseModel):
    
    salesperson_id: Optional[UUID] = None
    customer_id: Optional[UUID] = None
    status: SaleStatus = SaleStatus.ABERTA


class SaleUpdate(BaseModel):
    
    status: Optional[SaleStatus] = None
    customer_id: Optional[UUID] = None        
    total_discount: Optional[Decimal] = Field(default=None, ge=0)
    cancellation_reason: Optional[str] = None    


class SaleResponse(SaleBase):
    
    id: UUID
    cancelled_by: Optional[UUID]
    cancelled_at: Optional[datetime]
    cancellation_reason: Optional[str]    
    created_at: datetime
    finished_at: Optional[datetime]

    model_config = ConfigDict(from_attributes=True)