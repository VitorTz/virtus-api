from src.schemas.companies import CompanieResponse
from asyncpg import Connection
from typing import Optional
import json


async def create_cnpj_data(cnpj: str, data: dict, conn: Connection) -> dict:
    query = """
        INSERT INTO cnpjs (
            cnpj, 
            data
        ) 
        VALUES 
            ($1, $2)
        ON CONFLICT
            (cnpj)
        DO NOTHING
    """    
        
    string_json = json.dumps(data, ensure_ascii=False)
    await conn.execute(query, cnpj, string_json)
    
    return data


async def get_cnpj_data(cnpj: str, conn: Connection) -> Optional[CompanieResponse]:
    query = """
        SELECT             
            data, 
            created_at 
        FROM 
            cnpjs
        WHERE
            cnpj = $1
    """
    
    row = await conn.fetchrow(query, cnpj)
    
    if row:
        return CompanieResponse(data=json.loads(row['data']), created_at=row['created_at'])