from fastapi import APIRouter, Depends, Query, status
from fastapi.exceptions import HTTPException
from src.schemas.address import AddressResponse, AddressCreate, UserAddressCreate
from src.schemas.rls import RLSConnection
from src.model import address as address_model
from src.security import get_postgres_connection, get_rls_connection
from src.util import remove_non_digits
from src.db.db import db_safe_exec
from asyncpg import Connection
from typing import Optional
import requests


router = APIRouter()


async def _get_cep(cep: str, conn: Connection) -> AddressResponse:
    original_cep = cep
    cep: str = remove_non_digits(cep)
    address: Optional[AddressResponse] = await address_model.get_address(cep, conn)
    
    if address: return address
        
    url = f"https://viacep.com.br/ws/{cep}/json/"
    
    try:
        resp = requests.get(url, timeout=5)
    except Exception:
        raise HTTPException(detail=f"CEP {original_cep} não encontrado." , status_code=status.HTTP_404_NOT_FOUND)
    
    if resp.status_code != 200:
        raise HTTPException(detail=f"CEP {original_cep} não encontrado." , status_code=status.HTTP_404_NOT_FOUND)
    
    data = resp.json()
    address_create = AddressCreate(
        cep=cep,
        street=data.get("logradouro"),
        complement=data.get("complemento"),
        unit=data.get("unidade"),
        neighborhood=data.get("bairro"),
        city=data.get("localidade"),
        state_code=data.get("uf"),
        state=data.get("estado"),
        region=data.get("regiao"),
        ibge_code=data.get("ibge"),
        gia_code=data.get("gia"),
        area_code=data.get("ddd"),
        siafi_code=data.get("siafi")
    )
    
    return await db_safe_exec(address_model.create_address(address_create, conn))


@router.get("/", status_code=status.HTTP_200_OK, response_model=AddressResponse)
async def get_cep(cep: str = Query(), conn: Connection = Depends(get_postgres_connection)):
    return await _get_cep(cep, conn)


@router.post("/users", status_code=status.HTTP_204_NO_CONTENT)
async def register_user_address(
    address: UserAddressCreate, 
    rls: RLSConnection = Depends(get_rls_connection)
):
    await address_model.create_user_address(address, rls.conn)