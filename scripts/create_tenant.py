from dotenv import load_dotenv
import psycopg
import os
import re


load_dotenv()


def clean_cnpj(cnpj: str) -> str:
    """Remove tudo que não for dígito."""
    return re.sub(r'\D', '', cnpj)


def create_tenant():
    db_url = os.getenv("DATABASE_URL")
    if not db_url:
        print("Erro: DATABASE_URL não definida.")
        return

    print("--- [CRIAR NOVO TENANT / LOJA] ---")
    
    try:
        # Inputs
        name = input("Nome da Empresa/Loja: ").strip()
        cnpj_input = input("CNPJ (com ou sem pontuação): ").strip()
        notes = input("Observações (Opcional): ").strip()

        # Validação Básica
        if not name:
            print("Erro: O nome é obrigatório.")
            return

        cnpj_clean = clean_cnpj(cnpj_input)
        
        # Validação de formato (Opcional, mas recomendada)
        if cnpj_clean and len(cnpj_clean) != 14:
            print(f"Aviso: Um CNPJ válido geralmente tem 14 dígitos. Você digitou {len(cnpj_clean)}.")
            confirm = input("Deseja continuar mesmo assim? (s/n): ")
            if confirm.lower() != 's':
                return

        # Se o usuário deixou vazio, enviamos None (NULL no banco)
        # Mas cuidado: sua constraint UNIQUE permite vários NULLs, 
        # porém tenants sem CNPJ são raros em sistemas sérios.
        cnpj_final = cnpj_clean if cnpj_clean else None

        # CONEXÃO SEGURA
        with psycopg.connect(db_url) as conn:
            with conn.cursor() as cur:
                
                print("Criando Tenant no banco de dados...")
                
                cur.execute(
                    """
                    INSERT INTO tenants (
                        name,
                        cnpj,
                        notes,
                        is_active
                    )
                    VALUES (
                        %s,  -- name (CITEXT lida com case insensitive)
                        %s,  -- cnpj (VARCHAR 14)
                        %s,  -- notes
                        TRUE -- is_active default
                    )
                    RETURNING id;
                    """,
                    (name, cnpj_final, notes)
                )

                tenant_id = cur.fetchone()

                if tenant_id:
                    conn.commit()
                    
                    uuid_str = str(tenant_id[0])
                    
                    print("="*50)
                    print(f" [SUCESSO] Tenant criado com glória!")
                    print("="*50)
                    print(f" Nome:  {name}")
                    print(f" CNPJ:  {cnpj_final if cnpj_final else 'N/A'}")
                    print(f" ID:    {uuid_str}")
                    print("="*50)
                    print("--> COPIE O ID ACIMA. Você precisará dele para criar o Admin.")
                else:
                    print("[ERRO] O banco não retornou o ID do Tenant.")

    except psycopg.errors.UniqueViolation:
        print(f"\n[ERRO] Já existe um Tenant cadastrado com o CNPJ '{cnpj_clean}'.")
    except Exception as e:
        print(f"\n[ERRO FATAL] {e}")

if __name__ == "__main__":
    create_tenant()