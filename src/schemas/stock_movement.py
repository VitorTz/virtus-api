from pydantic import BaseModel, Field, ConfigDict, model_validator
from src.schemas.enums import StockMovementType
from datetime import datetime
from decimal import Decimal
from typing import Optional
from uuid import UUID


class StockMovementBase(BaseModel):
    
    product_id: UUID = Field(..., description="Produto movimentado")
    
    type: StockMovementType = Field(
        ..., 
        description="Tipo (VENDA, COMPRA, PERDA, etc)"
    )
    
    quantity: Decimal = Field(
        ..., 
        decimal_places=3,
        description="Quantidade movimentada. Positivo=Entrada, Negativo=Saída."
    )
    
    reference_id: Optional[UUID] = Field(
        default=None, 
        description="ID da Venda ou Compra (se houver)"
    )
    
    reason: Optional[str] = Field(
        default=None, 
        description="Motivo manual (ex: 'Garrafa quebrou na reposição')"
    )



class StockMovementCreate(StockMovementBase):

    created_by: Optional[UUID] = Field(
        default=None, 
        description="Usuário responsável pela ação"
    )
    
    @model_validator(mode='after')
    def validate_sign_logic(self):
        # Tipos que OBRIGATORIAMENTE reduzem estoque (devem ser negativos)
        output_types = [
            StockMovementType.VENDA,
            StockMovementType.PERDA,
            StockMovementType.CONSUMO_INTERNO,
            StockMovementType.DEVOLUCAO_FORNECEDOR,
            StockMovementType.CANCELAMENTO # Depende da lógica, assumindo cancelamento de compra
        ]
        
        # Tipos que OBRIGATORIAMENTE aumentam estoque (devem ser positivos)
        input_types = [
            StockMovementType.COMPRA,
            StockMovementType.DEVOLUCAO_VENDA
        ]        

        if self.type in output_types and self.quantity > 0:
            raise ValueError(f"Para o tipo {self.type.value}, a quantidade deve ser negativa (saída).")
            
        if self.type in input_types and self.quantity < 0:
            raise ValueError(f"Para o tipo {self.type.value}, a quantidade deve ser positiva (entrada).")

        return self


class StockMovementResponse(StockMovementBase):
    """
    Retorno do histórico.
    """
    id: UUID
    created_by: Optional[UUID]
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)