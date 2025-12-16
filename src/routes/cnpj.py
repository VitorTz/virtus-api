from fastapi import APIRouter, Depends, Query, status
from fastapi.exceptions import HTTPException
from src.schemas.companies import CompanieResponse
from src.model import cnpj as cnpj_model
from src.security import get_postgres_connection
from src.util import remove_non_digits, minutes_since
from asyncpg import Connection
from typing import Optional
import requests


TIME = 60 * 24 * 30 * 2


router = APIRouter()


@router.get("/")
async def get_company(
    cnpj: str = Query(),
    conn: Connection = Depends(get_postgres_connection)
) -> dict:
    original_cnpj = cnpj
    cnpj: str = remove_non_digits(cnpj)
    companie: Optional[CompanieResponse] = await cnpj_model.get_cnpj_data(cnpj, conn)
    
    if companie and minutes_since(companie.created_at) < TIME:
        return companie.data
    
    url = "https://brasilapi.com.br/api/cnpj/v1/" + cnpj
    resp = requests.get(url)
    
    if resp.status_code != 200:
        raise HTTPException(detail=f"CNPJ {original_cnpj} não encontrado." , status_code=status.HTTP_404_NOT_FOUND)
    
    return await cnpj_model.create_cnpj_data(
        cnpj,
        resp.json(),
        conn
    )