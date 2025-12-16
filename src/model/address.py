from src.schemas.address import AddressResponse, AddressCreate, UserAddressCreate
from asyncpg import Connection
from typing import Optional
from src import util


async def get_address(cep: str, conn: Connection) -> Optional[AddressResponse]:
    row = await conn.fetchrow(
        """
            SELECT
                *
            FROM
                addresses
            WHERE
                cep = $1
        """,
        cep
    )
    return AddressResponse(**dict(row)) if row else None


async def create_address(address: AddressCreate, conn: Connection) -> AddressResponse:
    row = await conn.fetchrow(
        """
            INSERT INTO addresses (
                cep,
                street,
                complement,
                unit,
                neighborhood,
                city,
                state_code,
                state,
                region,
                ibge_code,
                gia_code,
                area_code,
                siafi_code
            )
            VALUES
                ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
            ON CONFLICT
                (cep)
            DO UPDATE SET
                street = EXCLUDED.street,
                complement = EXCLUDED.complement,
                unit = EXCLUDED.unit,
                neighborhood = EXCLUDED.neighborhood,
                city = EXCLUDED.city,
                state_code = EXCLUDED.state_code,
                region = EXCLUDED.region,
                ibge_code = EXCLUDED.ibge_code,
                gia_code = EXCLUDED.gia_code,
                area_code = EXCLUDED.area_code,
                siafi_code = EXCLUDED.siafi_code,
                updated_at = CURRENT_TIMESTAMP
            RETURNING
                *
        """,
        address.cep,
        address.street,
        address.complement,
        address.unit,
        address.neighborhood,
        address.city,
        address.state_code,
        address.state,
        address.region,
        address.ibge_code,
        address.gia_code,
        address.area_code,
        address.siafi_code
    )
    
    return AddressResponse(**dict(row)) if row else None


async def create_user_address(address: UserAddressCreate, conn: Connection) -> None:
    ad: Optional[AddressResponse] = await get_address(util.remove_non_digits(address.cep), conn)
    if not ad:
        
        await create_address()