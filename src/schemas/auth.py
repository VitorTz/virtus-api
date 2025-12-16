from pydantic import BaseModel, Field, field_validator


class LoginRequest(BaseModel):
        
    identifier: str = Field(
        ..., 
        description="Email ou CPF do usuário"
    )
    password: str = Field(
        ...,
        description="Senha em texto plano"
    )
    
    fingerprint: str = Field(
        ...,
        description='Identificador único do cliente que está fazendo a requisição.'
    )

    @field_validator('identifier')
    @classmethod
    def validate_identifier(cls, v: str) -> str:
        return v.strip()

    @field_validator('password')
    @classmethod
    def validate_password(cls, v: str) -> str:
        return v.strip()
    
    @field_validator('fingerprint')
    @classmethod
    def validate_fingerprint(cls, v: str) -> str:
        return v.strip()