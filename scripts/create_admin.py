from fastapi import status
from fastapi.exceptions import HTTPException
from dotenv import load_dotenv
from passlib.context import CryptContext
import psycopg
import os


INVALID_PASSWORD_EXCEPTION = HTTPException(
    status_code=status.HTTP_400_BAD_REQUEST,
    detail="Password must be at least 8 characters long"
)

load_dotenv()

pwd_context = CryptContext(
    schemes=["argon2"],     
    deprecated="auto"
)


def remove_non_numbers(word: str) -> str:
    r = ''
    for letter in word:
        if letter.isdigit():
            r += letter
    return r


def hash_password(password: str) -> str:
    if not password or len(password) < 8:
        raise INVALID_PASSWORD_EXCEPTION
    return pwd_context.hash(password)


def create_superuser():
    db_url = os.getenv("DATABASE_URL")
    if not db_url:
        print("Erro: DATABASE_URL não definida.")
        return

    print("--- [CRIAR SUPERUSER / ADMIN] ---")
    try:
        # Inputs limpos
        name = input("Nome: ").strip()
        email = input("Email: ").strip()
        phone = remove_non_numbers(input("Telefone (apenas números): "))
        cpf = remove_non_numbers(input("CPF (apenas números): "))
        raw_password = input("Senha: ").strip()
        tenant_id_str = input("Tenant UUID: ").strip()

        # Validação básica pré-banco
        if not tenant_id_str or not email or not raw_password:
            print("Erro: Campos obrigatórios vazios.")
            return

        hashed = hash_password(raw_password)
        
        with psycopg.connect(db_url) as conn:
            with conn.cursor() as cur:
                cur.execute("SET app.is_system_action = 'true';")
                cur.execute(
                    """
                    INSERT INTO users (
                        name,
                        email,
                        password_hash,
                        phone,
                        cpf,
                        tenant_id,
                        roles,
                        is_active,
                        created_by
                    )
                    VALUES (
                        %s,
                        LOWER(TRIM(%s)),
                        %s,
                        %s,
                        %s,
                        %s,
                        %s::user_role_enum[],
                        TRUE,
                        NULL
                    )
                    RETURNING id;
                    """,
                    (
                        name, 
                        email, 
                        hashed, 
                        phone, 
                        None if not cpf else cpf, 
                        tenant_id_str, 
                        ['ADMIN']
                    )
                )

                new_id = cur.fetchone()
                
                if new_id:
                    conn.commit()
                    print(f"\n[SUCESSO] Admin criado! ID: {new_id[0]}")
                    print(f"Login: {email.lower()}")
                else:
                    print("\n[ERRO] O banco não retornou o ID. Algo estranho aconteceu.")

    except psycopg.errors.UniqueViolation:
        print("[ERRO DE DUPLICIDADE] Já existe um usuário com este Email ou CPF neste Tenant.")
    except psycopg.errors.ForeignKeyViolation:
        print("[ERRO DE VÍNCULO] O Tenant ID informado não existe.")
    except Exception as e:
        print(f"[ERRO FATAL] {e}")

if __name__ == "__main__":
    create_superuser()