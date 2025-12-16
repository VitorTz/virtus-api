from pydantic import BaseModel, Field, ConfigDict
from src.schemas.enums import PaymentMethod
from typing import Optional
from datetime import datetime
from decimal import Decimal
from uuid import UUID


class TabPaymentBase(BaseModel):
    
    amount_paid: Decimal = Field(
        ..., 
        gt=0, 
        decimal_places=2,
        description="Valor sendo abatido da dívida (deve ser maior que zero)"
    )
    
    payment_method: PaymentMethod = Field(
        ..., 
        description="Como o cliente está pagando a dívida (Dinheiro, PIX, etc)"
    )
    
    observation: Optional[str] = Field(
        default=None, 
        description="Notas adicionais (ex: 'Pagou metade do mês passado')"
    )


class TabPaymentCreate(TabPaymentBase):
    
    sale_id: UUID = Field(
        ..., 
        description="ID da venda original que gerou o fiado"
    )    


class TabPaymentResponse(TabPaymentBase):
    
    id: UUID
    sale_id: UUID
    received_by: Optional[UUID]
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)