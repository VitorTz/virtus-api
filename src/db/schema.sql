-- ============================================================================
-- SCHEMA - SCMG
-- Sistema de gestão para pequeno comércio com bar, lanchonete, mercearia e lojas
-- ============================================================================

-- ============================================================================
-- EXTENSIONS
-- ============================================================================


CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS "unaccent";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "citext";

-- ============================================================================
-- AUX FUNCTIONS
-- ============================================================================
CREATE OR REPLACE FUNCTION public.immutable_unaccent(text)
  RETURNS text
  SET search_path = public, extensions, pg_temp
AS
$func$
SELECT unaccent('unaccent', $1)
$func$  LANGUAGE sql IMMUTABLE;


CREATE OR REPLACE FUNCTION get_database_health_check()
RETURNS JSONB 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_result JSONB;
    v_role_info RECORD;
    v_db_size TEXT;
    v_conn_count INT;
    v_conn_total INT;
    v_cache_hit_ratio NUMERIC;
BEGIN
    -- 1. Coleta informações da Role atual
    SELECT 
        rolsuper, 
        rolcreaterole, 
        rolcreatedb, 
        rolcanlogin, 
        rolreplication,
        rolbypassrls
    INTO v_role_info
    FROM pg_roles 
    WHERE rolname = session_user; -- session_user é quem logou de verdade

    -- 2. Coleta tamanho do banco (Formatado, ex: "150 MB")
    v_db_size := pg_size_pretty(pg_database_size(current_database()));

    -- 3. Coleta conexões ativas neste banco específico
    SELECT count(*) INTO v_conn_count 
    FROM pg_stat_activity 
    WHERE datname = current_database();

    -- 4. Cálculo simples de Cache Hit Ratio (Eficiência da memória RAM)
    -- Se for > 99%, seu banco está voando. Se for < 90%, precisa de mais RAM.
    SELECT 
        ROUND(
            (sum(heap_blks_hit) / (sum(heap_blks_hit) + sum(heap_blks_read) + 1)) * 100.0, 
            2
        )
    INTO v_cache_hit_ratio
    FROM pg_statio_user_tables;

    -- Monta o JSON final
    v_result := jsonb_build_object(
        'timestamp', now(),
        'session_context', jsonb_build_object(
            'database', current_database(),
            'schema_search_path', current_setting('search_path'),
            'connected_via_port', current_setting('port'),
            'server_address', inet_server_addr()
        ),
        'user_identity', jsonb_build_object(
            'session_user', session_user, -- Quem digitou a senha
            'current_user', current_user, -- Quem está executando agora (muda em SECURITY DEFINER)
            'is_superuser', v_role_info.rolsuper,
            'has_bypass_rls', v_role_info.rolbypassrls, -- CRUCIAL para seus testes
            'can_create_db', v_role_info.rolcreatedb,
            'can_create_role', v_role_info.rolcreaterole
        ),
        'metrics', jsonb_build_object(
            'database_size_human', v_db_size,
            'database_size_bytes', pg_database_size(current_database()),
            'active_connections', v_conn_count,
            'cache_hit_ratio_percent', v_cache_hit_ratio
        ),
        'system_health', jsonb_build_object(
            'version', version(),
            'uptime_since', pg_postmaster_start_time(), -- Quando o servidor ligou
            'rls_enforced_in_session', current_setting('row_security', true)
        )
    );

    RETURN v_result;
END;
$$;


-- Cria automaticamente tenant_id e created_by
CREATE OR REPLACE FUNCTION fn_set_tenant_and_creator()
RETURNS TRIGGER
SET search_path = public, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.tenant_id := COALESCE(NEW.tenant_id, current_user_tenant_id());
        NEW.created_by := COALESCE(NEW.created_by, current_user_id());
    ELSIF TG_OP = 'UPDATE' THEN
        NEW.tenant_id := OLD.tenant_id;
        NEW.created_by := OLD.created_by;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- API USER
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_runtime') THEN
        CREATE USER app_runtime WITH PASSWORD 'sua_senha_forte_aqui';
    END IF;
END $$;

-- 2. Permissões no schema public
GRANT USAGE ON SCHEMA public TO app_runtime;

-- Permissões em tabelas
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_runtime;

-- Permissões em sequences
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT USAGE, SELECT ON SEQUENCES TO app_runtime;

-- Permissões em Funções e Procedures (CORRIGIDO AQUI) 🛠️
-- O GRANT direto aceita PROCEDURES (Postgres 11+)
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_runtime;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO app_runtime;

-- Mas o ALTER DEFAULT PRIVILEGES exige 'ROUTINES' para cobrir ambos
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT EXECUTE ON ROUTINES TO app_runtime;

-- 3. Schema extensions
GRANT USAGE ON SCHEMA extensions TO app_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO app_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA extensions 
    GRANT EXECUTE ON ROUTINES TO app_runtime; -- Usei ROUTINES aqui também por segurança

-- 4. Habilitar Row Level Security
ALTER ROLE app_runtime SET row_security = on;

-- 5. Configurações de segurança
ALTER ROLE app_runtime SET statement_timeout = '30s';
ALTER ROLE app_runtime SET idle_in_transaction_session_timeout = '60s';
-- ============================================================================
-- ENUMS
-- ============================================================================

DO $$ BEGIN
    -- Métodos de pagamento aceitos no estabelecimento
    CREATE TYPE payment_method_enum AS ENUM (
        -- Básicos
        'DINHEIRO',
        'PIX',
        
        -- Cartões (Importante separar para taxas de maquininha)
        'CARTAO_CREDITO',
        'CARTAO_DEBITO',
        
        -- Voucher / Benefícios (Crucial diferenciar para Mercados vs Restaurantes)
        'VALE_ALIMENTACAO',    -- VA (Supermercados)
        'VALE_REFEICAO',       -- VR (Restaurantes/Bares)
        'VALE_PRESENTE',       -- Gift Card da própria loja
        'VALE_COMBUSTIVEL',    -- Postos

        -- Crédito Loja / Interno
        'CREDIARIO',           -- O famoso "Fiado" ou "Conta Cliente"
        'CASHBACK',            -- Pagamento usando saldo de fidelidade/pontos
        'PERMUTA',             -- Troca de serviços/produtos (sem financeiro real)

        -- Bancário / B2B
        'BOLETO_BANCARIO',     -- Vendas a prazo com documento
        'TRANSFERENCIA_BANCARIA', -- TED/DOC (Mais raro no varejo, comum no B2B)
        'CHEQUE',              -- Ainda usado em atacados e cidades do interior

        -- Integrações Externas
        'CARTEIRA_DIGITAL',    -- PicPay, MercadoPago (quando não é via PIX direto)
        'APP_DELIVERY',        -- iFood/Rappi (O pagamento foi feito online, o dinheiro entra via repasse)
        
        -- Outros
        'SEM_PAGAMENTO',       -- Para bonificações ou cortesias 
        'OUTROS'
    );
    
    -- Tipos de movimentação de estoque
    CREATE TYPE stock_movement_enum AS ENUM (
        -- Operações Normais
        'VENDA',                -- Saída por venda fiscal
        'COMPRA',               -- Entrada por nota fiscal de fornecedor
        'BONIFICACAO',          -- Entrada gratuita (brinde de fornecedor) - não gera custo, mas gera estoque

        -- Devoluções (Logística Reversa)
        'DEVOLUCAO_CLIENTE',    -- Entrada (Cliente devolveu produto)
        'DEVOLUCAO_FORNECEDOR', -- Saída (Devolução de lote com defeito para a fábrica)

        -- Perdas e Quebras (Saídas Negativas)
        'PERDA',                -- Perda genérica (sumiu)
        'QUEBRA',               -- Acidente operacional (derrubou a garrafa)
        'VENCIMENTO',           -- Produto estragou/venceu validade
        'FURTO',                -- Furto identificado
        'AVARIA',               -- Produto danificado (riscado, amassado)

        -- Ajustes Administrativos
        'AJUSTE_ENTRADA',       -- Correção manual de inventário (+1)
        'AJUSTE_SAIDA',         -- Correção manual de inventário (-1)
        'INVENTARIO_INICIAL',   -- Carga inicial do sistema

        -- Uso Interno
        'CONSUMO_INTERNO',      -- Os funcionários comeram/usaram (café, limpeza)
        'DEGUSTACAO',           -- Aberto para cliente provar (marketing)

        -- Produção (Ficha Técnica / Transformação)
        -- Ex: Sai 200g de Farinha (PRODUCAO_SAIDA) -> Entra 1 Pão (PRODUCAO_ENTRADA)
        'PRODUCAO_ENTRADA',     -- Entrada do produto acabado
        'PRODUCAO_SAIDA',       -- Baixa dos insumos/ingredientes

        -- Movimentação entre Locais (Filiais/Depósitos)
        'TRANSFERENCIA_ENTRADA',
        'TRANSFERENCIA_SAIDA',

        'CANCELAMENTO'
    );
    
    -- Papéis/funções dos usuários no sistema
    CREATE TYPE user_role_enum AS ENUM (
        -- Alto Nível / Administrativo
        'ADMIN',        -- Acesso total (Dono)
        'GERENTE',      -- Gestão de equipe, relatórios, anulações, sangrias
        'CONTADOR',     -- Acesso apenas a relatórios fiscais e XMLs
        'FINANCEIRO',   -- Contas a pagar/receber, DRE (diferente do Contador e do Caixa)

        -- Operacional Varejo (Supermercados/Lojas)
        'CAIXA',        -- Frente de loja (PDV), abertura/fechamento
        'FISCAL_CAIXA', -- (Supervisor) Libera descontos, cancelamentos no PDV, mas não gerencia a loja toda
        'VENDEDOR',     -- Focado em comissão/pré-venda (comum em lojas de roupa/eletrônicos). Cria o pedido, mas o Caixa cobra.
        'REPOSITOR',    -- Focado em conferência de preço na gôndola e organização (não necessariamente mexe no estoque sistêmico)
        'ESTOQUISTA',   -- Entrada de NF, inventário, conferência cega
        'COMPRADOR',    -- Gera ordens de compra, negocia com fornecedor (diferente de quem recebe a mercadoria)

        -- Operacional Gastronomia (Bares/Restaurantes)
        'GARCOM',       -- Lança pedidos em mesas/comandas, transfere itens, pede fechamento (Mobile)
        'COZINHA',      -- Acesso a telas KDS (Kitchen Display System), baixa de insumos de produção
        'BARMAN',       -- Similar a cozinha, mas focado no bar (pode ter permissão de "auto-serviço" se lançar direto)
        'ENTREGADOR',   -- Acesso ao módulo de Delivery (rotas, confirmar entrega, baixa no app)

        -- Acesso Externo
        'CLIENTE'       -- Autoatendimento, Ecommerce ou App de fidelidade
    );
    
    -- Status possíveis de uma venda
    CREATE TYPE sale_status_enum AS ENUM (
        -- Fluxo Básico (Varejo Rápido)
        'ABERTA',               -- Venda no carrinho, sendo passada no caixa
        'CONCLUIDA',            -- Paga e finalizada fiscalmente
        'CANCELADA',            -- Cancelada antes do pagamento

        -- Fluxo Financeiro/Pré-Venda
        'ORCAMENTO',            -- Cotação que ainda não virou venda (não baixa estoque)
        'AGUARDANDO_PAGAMENTO', -- Comum para PIX online ou Link de Pagamento
        'FIADO_PENDENTE',       -- Venda concluída na "caderneta", mas dinheiro não entrou no caixa ainda

        -- Fluxo Gastronomia (Cozinha/KDS)
        'EM_PREPARO',           -- Enviado para a cozinha/bar
        'PRONTO_SERVIR',        -- Cozinha finalizou, aguardando garçom

        -- Fluxo Logística/Delivery/Ecommerce
        'EM_SEPARACAO',         -- Pagamento aprovado, estoquista pegando itens (Picking)
        'AGUARDANDO_ENTREGA',   -- Embalado, esperando motoboy
        'EM_ENTREGA',           -- Saiu para entrega
        'ENTREGUE',             -- Cliente recebeu
        'DEVOLVIDA',            -- Cliente não encontrado ou recusou
        
        -- Fluxo Fiscal (Erros)
        'REJEITADA_SEFAZ'       -- Venda bloqueada pela receita (erro de NCM, tributo, etc)
    );
    
    -- Unidades de medida para produtos
    CREATE TYPE measure_unit_enum AS ENUM (
        -- Peso e Massa (Açougue, Padaria, Hortifruti)
        'KG',  -- Quilograma
        'G',   -- Grama (Essencial para fichas técnicas de receitas)
        'MG',  -- Miligrama (Comum em suplementos/farmácia)

        -- Volume (Bebidas, Limpeza)
        'L',   -- Litro
        'ML',  -- Mililitro (Doses de bebidas, latas)

        -- Unitários e Embalagens (Varejo Geral)
        'UN',  -- Unidade Simples
        'CX',  -- Caixa (Atacado)
        'PC',  -- Pacote (Diferente de caixa, ex: pacote de bolacha)
        'DZ',  -- Dúzia (Ovos)
        'FAR', -- Fardo (Refrigerantes, Cerveja)
        'KIT', -- Kit promocional (Cesta básica, Kit churrasco)
        'PAL', -- Palete (Logística/Atacarejo)
        'PAR', -- Par (Calçados)

        -- Dimensões (Material de Construção, Tecidos)
        'M',   -- Metro Linear (Fios, mangueiras)
        'M2',  -- Metro Quadrado (Pisos, Vidros)
        'M3',  -- Metro Cúbico (Areia, Concreto)

        -- Gastronomia (Bares e Restaurantes)
        'DOS', -- Dose (Destilados)
        'FAT', -- Fatia (Pizza, Tortas)
        'POR', -- Porção (Batata frita, petiscos)

        -- Serviços
        'HR',  -- Hora (Consultoria, Aluguel de quadra)
        'DIA'  -- Diária (Aluguel de equipamentos)
    );
    
    CREATE TYPE category_type_enum AS ENUM (
        'PRODUCT', 
        'SERVICE', 
        'MODIFIER'
    );

    CREATE TYPE product_type_enum AS ENUM (
        'STANDARD', -- Produto padrão (baixa estoque dele mesmo)
        'SERVICE',  -- Serviço (não movimenta estoque, ex: Taxa de Entrega, Mão de Obra)
        'COMBO',    -- Kit/Combo (baixa estoque dos componentes)
        'MODIFIER'  -- Item adicional (ex: Adicional de Bacon, Ponto da Carne)
    );

EXCEPTION
    WHEN duplicate_object THEN null;
END $$;


-- ============================================================================
-- FUNCTIONS - Funções auxiliares do banco de dados
-- ============================================================================

CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER SET search_path = public, extensions, pg_temp AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- ============================================================================
-- APP TOKENS
-- ============================================================================

CREATE TABLE IF NOT EXISTS app_tokens (
    service_name VARCHAR(50) PRIMARY KEY,
    access_token TEXT NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- FISCAL
-- ============================================================================

CREATE TABLE IF NOT EXISTS fiscal_payment_codes (
    method payment_method_enum PRIMARY KEY,
    sefaz_code VARCHAR(2) NOT NULL,
    descr TEXT
);


-- Inserção dos dados padrão da SEFAZ (Tabela atualizada)
INSERT INTO fiscal_payment_codes (method, sefaz_code, descr) VALUES
    ('DINHEIRO',               '01', 'Dinheiro'),
    ('CHEQUE',                 '02', 'Cheque'),
    ('CARTAO_CREDITO',         '03', 'Cartão de Crédito'),
    ('CARTAO_DEBITO',          '04', 'Cartão de Débito'),
    ('CREDIARIO',              '05', 'Crédito Loja (Fiado)'),
    ('VALE_ALIMENTACAO',       '10', 'Vale Alimentação'),
    ('VALE_REFEICAO',          '11', 'Vale Refeição'),
    ('VALE_PRESENTE',          '12', 'Vale Presente'),
    ('VALE_COMBUSTIVEL',       '13', 'Vale Combustível'),
    -- Códigos 14 (Duplicata Mercantil) geralmente mapeia para Boleto em alguns contextos ou Crediário
    ('BOLETO_BANCARIO',        '15', 'Boleto Bancário'), 
    ('TRANSFERENCIA_BANCARIA', '16', 'Depósito Bancário'),
    ('PIX',                    '17', 'Pagamento Instantâneo (PIX)'),
    ('CARTEIRA_DIGITAL',       '18', 'Transferência bancária, Carteira Digital'),
    ('CASHBACK',               '19', 'Programa de Fidelidade, Cashback'),
    ('APP_DELIVERY',           '99', 'Outros (Intermediadores)'), 
    ('SEM_PAGAMENTO',          '90', 'Sem pagamento (Bonificação)'),
    ('OUTROS',                 '99', 'Outros')
ON CONFLICT
    (method)
DO UPDATE SET 
    sefaz_code = EXCLUDED.sefaz_code,
    descr = EXCLUDED.descr;

-- ============================================================================
-- IBPT VERSION
-- ============================================================================

CREATE TABLE IF NOT EXISTS ibpt_versions (
    version TEXT PRIMARY KEY,
    valid_from DATE,
    valid_until DATE,
    source TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- NCM
-- ============================================================================

CREATE TABLE IF NOT EXISTS fiscal_ncms (    
    code TEXT NOT NULL PRIMARY KEY,
    description TEXT NOT NULL, -- Descrição oficial (Ex: "Cervejas de malte")
    -- Alíquotas aproximadas (Lei 12.741/2012 - De Olho no Imposto)
    federal_national_rate NUMERIC(5, 2) DEFAULT 0, -- Imposto Federal (Produtos Nacionais)
    federal_import_rate NUMERIC(5, 2) DEFAULT 0,   -- Imposto Federal (Produtos Importados)
    state_rate NUMERIC(5, 2) DEFAULT 0,            -- Imposto Estadual (ICMS aproximado)
    municipal_rate NUMERIC(5, 2) DEFAULT 0,        -- Imposto Municipal (Serviços)
    fts_vector tsvector GENERATED ALWAYS AS (to_tsvector('portuguese', immutable_unaccent(description))) STORED
);


CREATE INDEX IF NOT EXISTS idx_fiscal_ncms_fts ON fiscal_ncms USING GIN (fts_vector);


CREATE OR REPLACE FUNCTION search_ncms_optimized(
    search_term TEXT, 
    p_limit INTEGER DEFAULT 64, 
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    -- Listamos as colunas explicitamente para adicionar o total_count
    code TEXT,
    description TEXT,
    federal_national_rate NUMERIC,
    federal_import_rate NUMERIC,
    state_rate NUMERIC,
    municipal_rate NUMERIC,    
    fts_vector tsvector,
    total_count INTEGER
) AS $$
DECLARE
    formatted_query tsquery;
    clean_term TEXT;
BEGIN
    clean_term := immutable_unaccent(trim(search_term));

    -- CASO 1: Termo vazio (Retorna tudo ordenado por código)
    IF clean_term = '' THEN
        RETURN QUERY
        SELECT 
            f.code,
            f.description, 
            f.federal_national_rate, 
            f.federal_import_rate, 
            f.state_rate, 
            f.municipal_rate,
            f.fts_vector,
            COUNT(*) OVER()::INTEGER AS total_count
        FROM 
            fiscal_ncms f
        ORDER BY 
            f.code ASC
        LIMIT 
            p_limit
        OFFSET 
            p_offset;
        RETURN;
    END IF;

    -- CASO 2: Busca com termo
    formatted_query := to_tsquery('portuguese', replace(clean_term, ' ', ':* & ') || ':*');

    RETURN QUERY
    SELECT 
        f.code,
        f.description, 
        f.federal_national_rate, 
        f.federal_import_rate, 
        f.state_rate, 
        f.municipal_rate,        
        f.fts_vector,
        COUNT(*) OVER()::INTEGER AS total_count
    FROM 
        fiscal_ncms f
    WHERE 
        f.code = search_term
        OR 
        f.fts_vector @@ formatted_query
    ORDER BY 
        (CASE WHEN f.code = search_term THEN 10.0 ELSE 0.0 END) DESC,
        ts_rank(f.fts_vector, formatted_query) DESC
    LIMIT
        p_limit
    OFFSET
        p_offset;

END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- CNPJS
-- ============================================================================

CREATE TABLE IF NOT EXISTS cnpjs (
    cnpj VARCHAR(14) PRIMARY KEY, -- Apenas números
    
    -- Identificação
    name CITEXT,       -- Razão Social
    trade_name CITEXT, -- Nome Fantasia
        
    -- Tributário
    is_simples BOOLEAN DEFAULT FALSE, -- Se é optante pelo Simples
    is_mei BOOLEAN DEFAULT FALSE,     -- Se é MEI
    cnae_main_code VARCHAR(10),       -- Código da atividade principal
    cnae_main_desc TEXT,    

    -- Endereço
    zip_code VARCHAR(8),
    street TEXT,
    number VARCHAR(20),
    complement TEXT,
    neighborhood TEXT,
    city_name TEXT,
    city_code VARCHAR(7),
    state CHAR(2),

    -- Contato
    email TEXT,
    phone TEXT,

    -- raw data
    raw_source_cnpj JSONB,
    last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- TENANTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS tenants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name CITEXT NOT NULL,
    cnpj VARCHAR(14),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_active BOOLEAN DEFAULT TRUE,
    notes TEXT,
    CONSTRAINT tenants_unique_cnpj UNIQUE (cnpj)
);


-- ============================================================================
-- ROLE CONFIG
-- ============================================================================

CREATE TABLE IF NOT EXISTS role_configs (
    role_name user_role_enum PRIMARY KEY,
    level_weight INTEGER NOT NULL DEFAULT 0,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Popula com os seus dados atuais
INSERT INTO role_configs (role_name, level_weight, description) VALUES
    ('ADMIN', 120, 'Acesso total ao sistema'),
    ('GERENTE', 99, 'Gestão de loja e equipe'),
    ('FINANCEIRO', 92, 'Acesso a relatórios financeiros e caixa'),
    ('CONTADOR', 80, 'Exportação de dados fiscais'),
    ('FISCAL_CAIXA', 70, 'Gerente de frente de caixa'),
    ('COMPRADOR', 60, 'Gestão de estoque e compras'),
    ('CAIXA', 50, 'Operador de PDV'),
    ('VENDEDOR', 50, 'Vendas e orçamentos'),
    ('GARCOM', 50, 'Pedidos e mesas'),
    ('ESTOQUISTA', 40, 'Conferência e entrada de notas'),
    ('BARMAN', 30, 'Produção de bebidas'),
    ('COZINHA', 30, 'Produção de pratos'),
    ('ENTREGADOR', 20, 'Logística e entrega'),
    ('REPOSITOR', 20, 'Organização de gôndola'),
    ('CLIENTE', 0, 'Consumidor final')
ON CONFLICT
    (role_name)
DO UPDATE SET
    level_weight = EXCLUDED.level_weight,
    description = EXCLUDED.description;


CREATE OR REPLACE FUNCTION trg_update_users_on_config_change()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.level_weight IS DISTINCT FROM NEW.level_weight THEN
        UPDATE users
        SET updated_at = CURRENT_TIMESTAMP
        WHERE NEW.role_name = ANY(roles);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER refresh_users_privileges
AFTER UPDATE ON role_configs
FOR EACH ROW
EXECUTE FUNCTION trg_update_users_on_config_change();


-- ============================================================================
-- USUÁRIOS
-- ============================================================================

CREATE TABLE IF NOT EXISTS users (

    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    nickname TEXT,
    birth_date DATE,
    email CITEXT,
    phone TEXT,
    cpf VARCHAR(14),
    image_url TEXT, -- Foto do funcionário (aparece no PDV) ou do cliente
    
    -- Segurança e Acesso
    password_hash TEXT, -- Senha forte (Acesso Web/Admin)
    quick_access_pin_hash TEXT, -- PIN numérico hasheado (Acesso rápido PDV Touch)
    
    -- Fiscal e Financeiro (Cliente)
    state_tax_indicator INTEGER DEFAULT 9,
    loyalty_points INTEGER DEFAULT 0, -- Pontos de Fidelidade acumulados

    -- Profissional (Funcionário)
    commission_percentage NUMERIC(5, 2) DEFAULT 0, -- Ex: 10% para garçom, 2% para vendedor

    max_privilege_level INTEGER DEFAULT 0,

    -- Status e Bloqueio
    is_active BOOLEAN NOT NULL DEFAULT TRUE, -- Soft Delete
    last_login_at TIMESTAMP,
    failed_login_attempts INTEGER DEFAULT 0,
    account_locked_until TIMESTAMP,
    notes TEXT,

    -- Auditoria
    tenant_id UUID NOT NULL,
    created_by UUID,
    
    roles user_role_enum[] NOT NULL DEFAULT '{CLIENTE}',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT users_roles_not_empty CHECK (roles IS NOT NULL AND array_length(roles, 1) > 0),
    CONSTRAINT users_valid_cpf_cstr CHECK (cpf IS NULL OR cpf ~ '^\d{11}$'),
    CONSTRAINT users_valid_email_cstr CHECK (
        email IS NULL OR (
            email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
            AND email NOT LIKE '%..%'
            AND length(email) >= 6
        )
    ),
    CONSTRAINT users_name_length_cstr CHECK (length(name) BETWEEN 2 AND 256),
    CONSTRAINT users_commission_chk CHECK (commission_percentage BETWEEN 0 AND 100)
);


-- Índices
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_cpf ON users(cpf);
CREATE INDEX IF NOT EXISTS idx_users_name ON users USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_users_tenant ON users USING btree (tenant_id);
CREATE INDEX IF NOT EXISTS idx_users_roles ON users USING gin (roles);
CREATE INDEX IF NOT EXISTS idx_users_privilege_level_desc ON users(tenant_id, max_privilege_level DESC) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_users_privilege_level_asc ON users(tenant_id, max_privilege_level ASC) WHERE is_active = TRUE;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_unique ON users(email, tenant_id) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_cpf_unique ON users(cpf, tenant_id) WHERE cpf IS NOT NULL;


CREATE OR REPLACE FUNCTION trg_calculate_max_privilege()
RETURNS TRIGGER AS $$
BEGIN    
    SELECT 
        COALESCE(MAX(level_weight), 0)
    INTO 
        NEW.max_privilege_level
    FROM 
        role_configs
    WHERE 
        role_name = ANY(NEW.roles);    
    RETURN 
        NEW;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE TRIGGER set_max_privilege_on_user_change
BEFORE INSERT OR UPDATE ON users
FOR EACH ROW
EXECUTE FUNCTION trg_calculate_max_privilege();


CREATE OR REPLACE FUNCTION get_user_login_data(p_identifier TEXT)
RETURNS TABLE (
    id UUID,
    name TEXT,
    nickname TEXT,
    email TEXT,
    password_hash TEXT,
    notes TEXT,
    state_tax_indicator INTEGER,
    created_at TIMESTAMPTZ,
    created_by UUID,
    updated_at TIMESTAMPTZ,
    tenant_id UUID,
    roles user_role_enum[],
    max_privilege_level INTEGER
) 
SET search_path = public, extensions, pg_temp AS $$
DECLARE
    v_clean_input TEXT;
    v_is_email BOOLEAN;
BEGIN
    v_clean_input := TRIM(p_identifier);    
    v_is_email := (v_clean_input LIKE '%@%');

    RETURN QUERY
    SELECT 
        u.id,
        u.name,
        u.nickname,
        u.email::TEXT,
        u.password_hash,
        u.notes,
        u.state_tax_indicator,
        u.created_at::TIMESTAMPTZ,
        u.created_by,
        u.updated_at::TIMESTAMPTZ,
        u.tenant_id,
        u.roles,
        u.max_privilege_level
    FROM 
        users u
    WHERE
        CASE 
            WHEN v_is_email THEN
                u.email = v_clean_input
            ELSE
                u.cpf = regexp_replace(v_clean_input, '\D','','g')
        END
    LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- CATEGORIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS categories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),

    name CITEXT NOT NULL,
    descr TEXT,
    
    -- Hierarquia
    parent_id UUID,
    
    -- Controle Visual (Essencial para PDV Touch/Bares)
    color VARCHAR(7) DEFAULT '#FFFFFF', -- Ex: Hex code para o botão na tela
    icon VARCHAR(50), -- Ex: Nome do ícone (mdi-beer, fa-shirt) ou URL
    
    -- Organização e Comportamento
    sort_order INTEGER DEFAULT 0, -- Para forçar 'Bebidas' a aparecer antes de 'Outros'
    type category_type_enum NOT NULL DEFAULT 'PRODUCT',
    is_active BOOLEAN NOT NULL DEFAULT TRUE, -- Para esconder sazonais (ex: Natal) sem deletar
    is_featured BOOLEAN NOT NULL DEFAULT FALSE, -- Para aparecer na tela inicial/favoritos
    
    -- Gastronomia / Setores
    -- Define onde os itens dessa categoria são impressos (Cozinha, Bar, Copa)
    remote_printer_name VARCHAR(50), 

    -- Auditoria e Isolamento
    tenant_id UUID NOT NULL,
    created_by UUID,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT categories_name_length_cstr CHECK (length(name) BETWEEN 2 AND 100),    
    CONSTRAINT categories_unique_name_tenant_parent UNIQUE (tenant_id, parent_id, name),    
    CONSTRAINT categories_no_self_parent CHECK (id <> parent_id),    
    FOREIGN KEY (parent_id) REFERENCES categories(id) ON DELETE SET NULL ON UPDATE CASCADE,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
);


CREATE INDEX IF NOT EXISTS idx_categories_tenant_parent ON categories(tenant_id, parent_id);
CREATE INDEX IF NOT EXISTS idx_categories_name_search ON categories USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_categories_active_sort ON categories (tenant_id, sort_order, name) WHERE is_active = TRUE;

CREATE OR REPLACE TRIGGER trg_categories_updated_at
BEFORE UPDATE ON categories
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


CREATE OR REPLACE FUNCTION get_category_tree(target_tenant_id UUID)
RETURNS TABLE (
    id UUID,
    name CITEXT,
    parent_id UUID,
    level INTEGER,
    path TEXT
) SET search_path = public, extensions, pg_temp AS $$
BEGIN
    RETURN QUERY
    WITH RECURSIVE category_tree AS (
        -- 1. Âncora: Nível Raiz (Pai é NULL)
        SELECT 
            c.id, 
            c.name, 
            c.parent_id, 
            0 AS level, 
            CAST(c.name AS TEXT) AS path
        FROM categories c
        WHERE c.parent_id IS NULL 
          AND c.tenant_id = target_tenant_id
        
        UNION ALL
        
        -- 2. Recursão: Busca os filhos
        SELECT 
            c.id, 
            c.name, 
            c.parent_id, 
            ct.level + 1,
            CAST(ct.path || ' > ' || c.name AS TEXT)
        FROM categories c
        INNER JOIN category_tree ct ON c.parent_id = ct.id
        -- Nota: Não precisamos filtrar tenant_id aqui de novo, 
        -- pois os filhos herdam o contexto do pai pela chave estrangeira.
    )
    SELECT 
        ct.id, 
        ct.name, 
        ct.parent_id, 
        ct.level, 
        ct.path
    FROM category_tree ct
    ORDER BY ct.path;
END;
$$ LANGUAGE plpgsql STABLE;

-- ============================================================================
-- SUPPLIERS - Cadastro de fornecedores de produtos
-- ============================================================================

CREATE TABLE IF NOT EXISTS suppliers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- Identificação
    name CITEXT NOT NULL, -- Razão Social
    trade_name CITEXT,    -- Nome Fantasia (Como eles são conhecidos)
    
    -- Fiscal
    cnpj VARCHAR(14),     -- Apenas números
    cpf VARCHAR(11),      -- Para Produtor Rural
    ie VARCHAR(20),       -- Inscrição Estadual (CRUCIAL para NFe)
    im VARCHAR(20),       -- Inscrição Municipal (Serviços)
    
    -- Contato
    email CITEXT,
    phone VARCHAR(20),    -- Aceite formatação "(48) 9..."
    contact_name TEXT,    -- Com quem falar (Vendedor)
    website TEXT,
    
    -- Endereço Estruturado
    zip_code VARCHAR(8),  -- CEP (Apenas números)
    address TEXT,         -- Logradouro (Rua, Av, etc)
    number VARCHAR(20),   -- Pode ser "S/N", "KM 10", "123B"
    complement TEXT,      -- "Galpão 2", "Sala 304"
    neighborhood TEXT,    -- Bairro
    city_name TEXT,       -- Nome da Cidade (Visual)
    city_code VARCHAR(7), -- Código IBGE (Obrigatório para o XML da NFe)
    state CHAR(2),        -- UF (SC, PR, SP...)
    
    -- Operacional
    notes TEXT,           -- "Só entrega na terça", "Chamar no WhatsApp"
    lead_time INTEGER,    -- Tempo médio de entrega em dias (Ajuda no pedido de compra)
    
    -- Auditoria
    tenant_id UUID NOT NULL,
    created_by UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    -- Relacionamentos
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    
    -- 1. Garante que tem pelo menos UM documento (CPF ou CNPJ)
    CONSTRAINT suppliers_doc_check CHECK (cnpj IS NOT NULL OR cpf IS NOT NULL),
    
    -- 2. Unicidade por Tenant (Evita duplicar o fornecedor da Coca-Cola)
    CONSTRAINT suppliers_cnpj_unique UNIQUE (cnpj, tenant_id),
    CONSTRAINT suppliers_cpf_unique UNIQUE (cpf, tenant_id)
);

-- Índices para busca rápida no PDV
CREATE INDEX IF NOT EXISTS idx_suppliers_tenant_name ON suppliers(tenant_id, name);
CREATE INDEX IF NOT EXISTS idx_suppliers_trade_name ON suppliers(tenant_id, trade_name);

-- ============================================================================
-- TRIBUTAÇÃO
-- ============================================================================

CREATE TABLE IF NOT EXISTS tax_groups (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    description VARCHAR(100) NOT NULL,
    icms_cst VARCHAR(3) NOT NULL,
    pis_cofins_cst VARCHAR(2) NOT NULL,
    icms_rate NUMERIC(5,2) DEFAULT 0,
    pis_rate NUMERIC(5,2) DEFAULT 0,
    cofins_rate NUMERIC(5,2) DEFAULT 0,
    tenant_id UUID NOT NULL,
    created_by UUID,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_tax_groups_tenant_id ON tax_groups(tenant_id);


-- ============================================================================
-- PRODUCTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS products (    
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sku CITEXT NOT NULL,
    name CITEXT NOT NULL,
    description TEXT,
    image_url TEXT,
    
    -- Categorização
    category_id UUID NOT NULL,
    type product_type_enum NOT NULL DEFAULT 'STANDARD',
    
    -- Fiscal (Obrigatórios para NFe/NFCe)
    gtin VARCHAR(14), -- EAN/Barcode
    ncm VARCHAR(8),
    cest VARCHAR(7),
    cfop_default VARCHAR(4),
    origin CHAR(1) NOT NULL DEFAULT '0',
    tax_group_id UUID, -- Grupo tributário (regras de ICMS/PIS/COFINS)

    -- Estoque e Balança
    stock_quantity NUMERIC(15, 3) NOT NULL DEFAULT 0,
    min_stock_quantity NUMERIC(15, 3) DEFAULT 0,
    max_stock_quantity NUMERIC(15, 3),
    
    measure_unit measure_unit_enum NOT NULL DEFAULT 'UN',
    is_weighable BOOLEAN NOT NULL DEFAULT FALSE, -- Se TRUE, exporta para balança (Toledo/Filizola)
    average_weight NUMERIC(10, 4) DEFAULT 0.0, -- Peso médio (informativo) ou Tara
    
    -- Preços e Custos
    cost_price NUMERIC(15, 2) NOT NULL DEFAULT 0, -- Custo Médio (usado para margem)
    purchase_price NUMERIC(15, 2) NOT NULL DEFAULT 0, -- Preço da Última Compra (atualização rápida)
    sale_price NUMERIC(15, 2) NOT NULL DEFAULT 0, -- Preço de Venda Base
    
    -- Promoções (Supermercados usam muito)
    promo_price NUMERIC(15, 2), -- Preço promocional
    promo_start_at TIMESTAMP,
    promo_end_at TIMESTAMP,

    -- Margem Calculada (Baseada no Custo Médio e Preço de Venda ATUAL)
    -- Se houver promoção ativa no momento do SELECT, o cálculo deve ser feito na aplicação, 
    -- aqui calculamos a margem "Cheia".
    profit_margin NUMERIC(10, 2) GENERATED ALWAYS AS (
        CASE WHEN cost_price > 0 
        THEN ((sale_price - cost_price) / cost_price * 100) 
        ELSE 100 END
    ) STORED,

    -- Gastronomia / Bares
    needs_preparation BOOLEAN NOT NULL DEFAULT FALSE, -- Se TRUE, envia para KDS/Cozinha
    preparation_time INTEGER, -- Tempo estimado em minutos (para gestão de fila)
    remote_printer_name VARCHAR(50), -- Sobrescreve a impressora da Categoria (ex: Bebida na Copa, Petisco na Cozinha)
    
    -- Status e Controle
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_blocked_on_negative_stock BOOLEAN NOT NULL DEFAULT FALSE, -- Impede venda se estoque zerar

    -- Auditoria
    tenant_id UUID NOT NULL,
    created_by UUID,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Relacionamentos
    FOREIGN KEY (category_id) REFERENCES categories(id) ON UPDATE CASCADE,
    FOREIGN KEY (tax_group_id) REFERENCES tax_groups(id) ON DELETE SET NULL ON UPDATE CASCADE,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,

    -- Constraints
    CONSTRAINT products_sku_unique_cstr UNIQUE (sku, tenant_id),
    CONSTRAINT products_gtin_unique_cstr UNIQUE (gtin, tenant_id),
    CONSTRAINT products_sku_length_chk CHECK (sku IS NULL OR length(sku) BETWEEN 2 AND 128),
    CONSTRAINT products_promo_date_chk CHECK (promo_end_at > promo_start_at),
    CONSTRAINT products_promo_price_chk CHECK (promo_price IS NULL OR promo_price < sale_price)
);

CREATE INDEX IF NOT EXISTS idx_products_search_sku ON products USING btree(sku) WHERE sku IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_products_pos_list ON products(tenant_id, category_id, name) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_products_gtin ON products(tenant_id, gtin) WHERE gtin IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_products_low_stock ON products(tenant_id) WHERE stock_quantity <= min_stock_quantity AND is_active = TRUE AND type = 'STANDARD';
CREATE INDEX IF NOT EXISTS idx_products_active_stock ON products(tenant_id, is_active, stock_quantity) WHERE type = 'STANDARD';
CREATE INDEX IF NOT EXISTS idx_products_negative_stock ON products(tenant_id, stock_quantity) WHERE stock_quantity < 0;
CREATE INDEX IF NOT EXISTS idx_products_fts ON products USING GIN(
    (
        setweight(to_tsvector('portuguese', name), 'A') ||
        setweight(to_tsvector('portuguese', COALESCE(LEFT(description, 500), '')), 'B') ||
        setweight(to_tsvector('portuguese', sku), 'C')
    )
) WHERE is_active = TRUE;

CREATE OR REPLACE TRIGGER trg_products_updated_at
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();


CREATE OR REPLACE FUNCTION generate_numeric_sku(p_digits INT DEFAULT 5)
RETURNS TEXT SET search_path = public, extensions, pg_temp AS $$
DECLARE
    v_min BIGINT;
    v_max BIGINT;
BEGIN
    
    IF p_digits < 2 OR p_digits > 18 THEN
        p_digits := 6;
    END IF;

    v_min := power(10, p_digits - 1)::BIGINT;
    v_max := (power(10, p_digits)::BIGINT) - 1;

    RETURN floor(random() * (v_max - v_min + 1) + v_min)::text;
END;
$$ LANGUAGE plpgsql VOLATILE;


CREATE OR REPLACE FUNCTION ensure_unique_sku()
RETURNS TRIGGER SET search_path = public, extensions, pg_temp AS $$
DECLARE
    v_candidate TEXT;
    v_max_attempts INTEGER := 12;
    v_attempt INTEGER := 0;
BEGIN
    
    IF NEW.sku IS NOT NULL THEN
        RETURN NEW;
    END IF;
    
    LOOP
        v_attempt := v_attempt + 1;
        
        v_candidate := generate_numeric_sku();
                
        IF NOT EXISTS (
            SELECT 1 FROM products 
            WHERE tenant_id = NEW.tenant_id 
            AND sku = v_candidate
        ) THEN
            NEW.sku := v_candidate;
            RETURN NEW;
        END IF;
        
        IF v_attempt >= v_max_attempts THEN
            RAISE EXCEPTION 'Não foi possível gerar um SKU único após % tentativas. O universo de códigos está saturado?', v_max_attempts;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE TRIGGER trg_products_auto_sku
BEFORE INSERT ON products
FOR EACH ROW
EXECUTE FUNCTION ensure_unique_sku();


CREATE OR REPLACE FUNCTION search_products(search_query TEXT)
RETURNS TABLE (
    id UUID,
    name CITEXT,
    sku CITEXT,
    category_name CITEXT,
    stock_quantity NUMERIC,
    sale_price NUMERIC,
    relevance NUMERIC
) 
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    v_tenant_id UUID;
BEGIN
    -- Obter tenant_id das configurações da sessão
    v_tenant_id := current_user_tenant_id();
    
    -- Validar se o tenant_id está configurado
    IF v_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Tenant ID não configurado na sessão. Use set_config(''app.current_tenant_id'', ''tenant_uuid'')';
    END IF;
    
    -- Converter search_query para segurança (evitar injeção)
    search_query := trim(search_query);
    
    -- Validar query não vazia
    IF length(search_query) < 2 THEN
        RAISE EXCEPTION 'Query de busca deve ter pelo menos 2 caracteres';
    END IF;
    
    RETURN QUERY
    SELECT 
        p.id,
        p.name,
        p.sku,
        c.name as category_name,
        p.stock_quantity,
        COALESCE(
            CASE 
                WHEN p.promo_price IS NOT NULL 
                    AND p.promo_start_at <= NOW() 
                    AND p.promo_end_at >= NOW()
                THEN p.promo_price
                ELSE p.sale_price
            END,
            p.sale_price
        ) as sale_price,
        ts_rank(p.search_vector, plainto_tsquery('portuguese', search_query)) as relevance
    FROM products p
    JOIN categories c ON p.category_id = c.id
    WHERE p.tenant_id = v_tenant_id
      AND p.is_active = true
      AND (
        -- Busca full-text
        p.search_vector @@ websearch_to_tsquery('portuguese', search_query)
        -- Fallback para buscas por SKU exato
        OR (p.sku IS NOT NULL AND p.sku ILIKE '%' || search_query || '%')
        -- Fallback para busca por nome (para queries muito curtas)
        OR (length(search_query) <= 3 AND p.name ILIKE '%' || search_query || '%')
      )
    ORDER BY 
        -- Priorizar resultados exatos de SKU
        CASE WHEN p.sku ILIKE search_query THEN 0 ELSE 1 END,
        relevance DESC, 
        p.name
    LIMIT 100;
EXCEPTION
    WHEN OTHERS THEN
        -- Log do erro (opcional)
        RAISE NOTICE 'Erro na busca de produtos: %', SQLERRM;
        -- Retornar vazio em caso de erro
        RETURN;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- ============================================================================
-- PRODUCT COMPOSITIONS - Composição de produtos compostos
-- ============================================================================

CREATE TABLE IF NOT EXISTS product_compositions (
    parent_product_id UUID NOT NULL, -- O Produto do tipo 'COMBO'
    child_product_id UUID NOT NULL,  -- O Produto do tipo 'STANDARD'
    quantity NUMERIC(10, 3) NOT NULL, -- Quanto baixa do filho
    tenant_id UUID NOT NULL,
    PRIMARY KEY (parent_product_id, child_product_id),
    FOREIGN KEY (parent_product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (child_product_id) REFERENCES products(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS idx_compositions_tenant_parent ON product_compositions(tenant_id, parent_product_id);


-- ============================================================================
-- PRODUCT MOFIFIER GROUPS
-- ============================================================================

-- Ex: Grupo "Pontos da Carne", Min: 1, Max: 1 (Obrigatório escolher 1)
-- Ex: Grupo "Adicionais", Min: 0, Max: 5 (Opcional)
CREATE TABLE IF NOT EXISTS product_modifier_groups (
    product_id UUID NOT NULL, -- O Hamburger
    category_id UUID NOT NULL, -- A Categoria que contém os modificadores (ex: categoria 'Adicionais')
    tenant_id UUID NOT NULL,

    min_selection INTEGER DEFAULT 0,
    max_selection INTEGER DEFAULT 1,
    free_selection INTEGER DEFAULT 0, -- Quantos itens são grátis antes de cobrar
    
    PRIMARY KEY (product_id, category_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
);


-- ============================================================================
-- LOTES
-- ============================================================================

CREATE TABLE IF NOT EXISTS batches (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    -- Identificação
    product_id UUID NOT NULL,
    batch_code TEXT NOT NULL, -- Código impresso na embalagem
    
    -- Datas Críticas
    manufacturing_date DATE,
    expiration_date DATE NOT NULL,
    
    -- Quantidades e Custos (Essencial para Lucro Real e FIFO)
    initial_quantity NUMERIC(15, 3) NOT NULL, -- Quanto entrou originalmente
    current_quantity NUMERIC(15, 3) NOT NULL, -- Quanto tem agora
    unit_cost NUMERIC(15, 2) NOT NULL DEFAULT 0, -- Custo unitário DESTE lote específico

    -- Controle
    is_blocked BOOLEAN DEFAULT FALSE, -- Para Recall ou Quarentena
    block_reason TEXT,

    -- Auditoria
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    tenant_id UUID NOT NULL,
    created_by UUID,

    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    
    -- Validações
    CONSTRAINT batches_batch_code_length_cstr CHECK (length(batch_code) <= 64),
    CONSTRAINT batches_quantity_valid CHECK (current_quantity >= 0),
    CONSTRAINT batches_dates_check CHECK (expiration_date >= manufacturing_date),
    
    -- Um produto não pode ter dois lotes com mesmo código no mesmo tenant
    CONSTRAINT batches_unique_code_tenant UNIQUE (tenant_id, product_id, batch_code)
);

CREATE INDEX IF NOT EXISTS idx_batches_fifo ON batches(product_id, expiration_date ASC) WHERE current_quantity > 0 AND is_blocked = FALSE;

CREATE OR REPLACE TRIGGER trg_batches_updated_at
BEFORE UPDATE ON batches
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- ENDEREÇOS - Endereços de usuários/clientes
-- ============================================================================

CREATE TABLE IF NOT EXISTS addresses (
    cep TEXT NOT NULL PRIMARY KEY,
    street TEXT,                              -- logradouro
    complement TEXT,                          -- complemento
    unit TEXT,                                -- unidade
    neighborhood TEXT,                        -- bairro
    city TEXT,                                -- localidade
    state_code TEXT,                          -- uf
    state TEXT,                               -- estado
    region TEXT,                              -- regiao
    ibge_code TEXT,                           -- ibge_code
    gia_code TEXT,                            -- gia
    area_code TEXT,                           -- ddd
    siafi_code TEXT,                          -- siafi
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE TRIGGER trg_addresses_updated_at
BEFORE UPDATE ON addresses
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE IF NOT EXISTS user_addresses (
    user_id UUID NOT NULL,
    cep TEXT NOT NULL,
    descr TEXT,
    number TEXT,
    tenant_id UUID NOT NULL,
    PRIMARY KEY (user_id, cep),    
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (cep) REFERENCES addresses(cep) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE
);

-- ============================================================================
-- TOKENS DE SESSÃO
-- ============================================================================

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    revoked BOOLEAN DEFAULT FALSE,
    family_id UUID NOT NULL,
    replaced_by UUID REFERENCES refresh_tokens(id),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);


CREATE INDEX IF NOT EXISTS idx_refresh_token_users ON refresh_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_refresh_token_family ON refresh_tokens(family_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_active_family ON refresh_tokens(family_id) WHERE revoked = FALSE;
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_expires_at ON refresh_tokens (expires_at);


-- SELECT cron.schedule(
--     'delete_revoked_tokens',
--     '0 6 * * 0',
--     $$DELETE FROM refresh_tokens WHERE revoked = TRUE$$
-- );
-- SELECT * FROM cron.job;

-- ============================================================================
-- PRICE AUDITS - Histórico de alterações de preços
-- ============================================================================

CREATE TABLE IF NOT EXISTS price_audits (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL,
    old_purchase_price NUMERIC(10, 2),
    new_purchase_price NUMERIC(10, 2),
    old_sale_price NUMERIC(10, 2),
    new_sale_price NUMERIC(10, 2),
    tenant_id UUID NOT NULL,
    changed_by UUID,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (changed_by) REFERENCES users(id),
    FOREIGN KEY (changed_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_price_audits_product ON price_audits(product_id);
CREATE INDEX IF NOT EXISTS idx_price_audits_changed_at ON price_audits(changed_at DESC);

-- ============================================================================
-- STOCK MOVEMENTS - Todas as entradas e saídas
-- ============================================================================

CREATE TABLE IF NOT EXISTS stock_movements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    
    -- O Que e Onde
    tenant_id UUID NOT NULL,
    product_id UUID NOT NULL,
    batch_id UUID, -- Opcional (nem todo produto tem controle de lote)
    
    -- O Movimento
    type stock_movement_enum NOT NULL,
    quantity NUMERIC(15, 3) NOT NULL CHECK (quantity > 0), -- Sempre positivo, o tipo define o sinal
    
    -- Valores (Snapshot financeiro)
    unit_cost NUMERIC(15, 2) DEFAULT 0, -- Custo no momento da operação
    total_cost NUMERIC(15, 2) GENERATED ALWAYS AS (quantity * unit_cost) STORED,

    -- Rastreabilidade
    reference_id UUID, -- ID da Venda, ID da Compra, ID da Perda
    reason TEXT, -- "Garrafa quebrada pelo cliente", "Venda #123"
    
    -- Auditoria
    created_by UUID,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,    
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE CASCADE,
    FOREIGN KEY (batch_id) REFERENCES batches(id) ON UPDATE CASCADE, -- Se deletar o lote, mantemos o histórico (set null ou restrict seria melhor, mas cascade é prático)
    FOREIGN KEY (created_by) REFERENCES users(id) ON UPDATE CASCADE ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_stock_mv_tenant_prod_date ON stock_movements(tenant_id, product_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stock_mv_ref ON stock_movements(tenant_id, reference_id);
CREATE INDEX IF NOT EXISTS idx_stock_mv_batch ON stock_movements(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_stock_mv_report ON stock_movements(tenant_id, product_id, type, created_at DESC);


ALTER TABLE stock_movements SET (
    autovacuum_vacuum_scale_factor = 0.05,
    autovacuum_analyze_scale_factor = 0.02
);


CREATE OR REPLACE FUNCTION fn_update_stock_balance()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE products p
    SET stock_quantity = stock_quantity + agg.delta
    FROM (
        SELECT 
            product_id,
            SUM(
                CASE 
                    WHEN type IN ('COMPRA', 'DEVOLUCAO_CLIENTE', 'AJUSTE_ENTRADA', 'CANCELAMENTO') 
                    THEN quantity 
                    ELSE -quantity 
                END
            ) as delta
        FROM new_table
        GROUP BY product_id
    ) agg
    WHERE p.id = agg.product_id;
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_stock_movements_balance
AFTER INSERT ON stock_movements
FOR EACH ROW EXECUTE FUNCTION fn_update_stock_balance();


-- ============================================================================
-- FISCAL_SEQUENCES
-- ============================================================================

CREATE TABLE IF NOT EXISTS fiscal_sequences (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id UUID NOT NULL,
    
    -- Chave composta (Quem é a sequência?)
    series INTEGER NOT NULL DEFAULT 1,
    model VARCHAR(2) NOT NULL DEFAULT '65', -- 65=NFCe, 59=SAT, 55=NFe
    
    -- O contador
    current_number INTEGER NOT NULL DEFAULT 0,
    
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- Garante que só existe UM contador por Série/Modelo na Loja
    CONSTRAINT fiscal_sequences_unique_key UNIQUE (tenant_id, model, series),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE
);

-- ============================================================================
-- SALES
-- ============================================================================

CREATE TABLE IF NOT EXISTS sales (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    
    -- Totais
    subtotal NUMERIC(10, 2) NOT NULL DEFAULT 0,
    total_discount NUMERIC(10, 2) DEFAULT 0,
    shipping_fee NUMERIC(10, 2) DEFAULT 0, -- Taxa de entrega (Delivery)
    service_fee NUMERIC(10, 2) DEFAULT 0, -- Gorjeta
    total_amount NUMERIC(10, 2) NOT NULL DEFAULT 0, -- (Subtotal - Desc + Frete + Service Fee)
    
    status sale_status_enum DEFAULT 'ABERTA',

    -- Atores
    salesperson_id UUID, -- Quem vendeu (Comissão)
    customer_id UUID,    -- Quem comprou (CRM/Fiado)
    
    -- Gastronomia / Bares
    table_number INTEGER,   -- Número da Mesa
    command_number INTEGER, -- Número da Comanda/Ficha
    waiter_id UUID,         -- Garçom (diferente do caixa que fecha a conta)

    -- Dados Fiscais (Snapshot da Nota Fiscal)
    fiscal_key TEXT,     -- Chave de acesso da NFe/NFCe
    fiscal_number INTEGER,      -- Número da nota
    fiscal_series INTEGER,      -- Série
    fiscal_model VARCHAR(2),    -- '65' (NFCe) ou '59' (SAT)
    
    -- Cancelamento
    cancelled_by UUID,
    cancelled_at TIMESTAMP,
    cancellation_reason TEXT,

    -- Auditoria e Isolamento
    tenant_id UUID NOT NULL,
    created_by UUID, -- Quem abriu a venda (geralmente o Caixa)
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMP,
    
    CONSTRAINT check_sales_positive_amount CHECK (total_amount >= 0),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (salesperson_id) REFERENCES users(id) ON DELETE SET NULL,
    FOREIGN KEY (waiter_id) REFERENCES users(id) ON DELETE SET NULL,
    FOREIGN KEY (customer_id) REFERENCES users(id) ON DELETE SET NULL,
    FOREIGN KEY (cancelled_by) REFERENCES users(id) ON DELETE SET NULL,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL
);


CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_fiscal_key_unique ON sales(tenant_id, fiscal_key) WHERE fiscal_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sales_tenant ON sales(tenant_id);
-- 1. Impede duas mesas abertas iguais na mesma loja
CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_unique_open_table ON sales (tenant_id, table_number) WHERE status = 'ABERTA' AND table_number IS NOT NULL;
-- 2. Impede duas comandas abertas iguais na mesma loja
CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_unique_open_command ON sales (tenant_id, command_number) WHERE status = 'ABERTA' AND command_number IS NOT NULL;


CREATE OR REPLACE FUNCTION get_next_fiscal_number(
    p_tenant_id UUID,
    p_series INTEGER,
    p_model VARCHAR
) 
RETURNS INTEGER AS $$
DECLARE
    v_new_number INTEGER;
    v_max_retries INTEGER := 5;
    v_retry_count INTEGER := 0;
BEGIN
    LOOP
        BEGIN
            INSERT INTO fiscal_sequences (
                tenant_id, 
                series, 
                model, 
                current_number, 
                updated_at
            )
            VALUES 
                (p_tenant_id, p_series, p_model, 1, NOW())
            ON CONFLICT 
                (tenant_id, series, model) 
            DO UPDATE SET 
                current_number = fiscal_sequences.current_number + 1,
                updated_at = NOW()
            RETURNING current_number INTO v_new_number;
            
            RETURN v_new_number;
            
        EXCEPTION WHEN serialization_failure OR deadlock_detected THEN
            v_retry_count := v_retry_count + 1;
            IF v_retry_count >= v_max_retries THEN
                RAISE EXCEPTION 'Falha ao gerar número fiscal após % tentativas', v_max_retries;
            END IF;
            -- Espera exponencial: 10ms, 20ms, 40ms...
            PERFORM pg_sleep(0.01 * power(2, v_retry_count));
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp;


CREATE OR REPLACE FUNCTION fn_assign_fiscal_number()
RETURNS TRIGGER SET search_path = public, extensions, pg_temp AS $$
BEGIN
    -- Só age se a venda está sendo CONCLUÍDA e ainda não tem número
    IF NEW.status = 'CONCLUIDA' AND (OLD.status IS DISTINCT FROM 'CONCLUIDA') THEN
        
        -- Se já vier com número (ex: importação), não faz nada
        IF NEW.fiscal_number IS NOT NULL THEN
            RETURN NEW;
        END IF;

        -- Garante valores padrão para Série e Modelo se estiverem nulos
        NEW.fiscal_series := COALESCE(NEW.fiscal_series, 1);
        NEW.fiscal_model := COALESCE(NEW.fiscal_model, '65'); -- Padrão NFCe

        -- Chama a função que trava e incrementa
        NEW.fiscal_number := get_next_fiscal_number(
            NEW.tenant_id,
            NEW.fiscal_series,
            NEW.fiscal_model
        );
                
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- O Trigger deve ser BEFORE UPDATE
CREATE OR REPLACE TRIGGER trg_sales_assign_fiscal_number
BEFORE UPDATE ON sales
FOR EACH ROW
EXECUTE FUNCTION fn_assign_fiscal_number();


-- ============================================================================
-- ITENS DE VENDA - Produtos vendidos em cada venda
-- ============================================================================

CREATE TABLE IF NOT EXISTS sale_items (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    sale_id UUID NOT NULL,
    product_id UUID NOT NULL,

    batch_id UUID, -- De qual lote saiu esse produto? (Importante p/ validade)
    
    -- Quantidades e Preços
    quantity NUMERIC(10, 3) NOT NULL CHECK (quantity > 0),
    unit_sale_price NUMERIC(10, 2) NOT NULL, -- Preço unitário NA HORA da venda
    unit_cost_price NUMERIC(10, 2), -- Custo NA HORA da venda (p/ relatório de margem)
    
    discount_amount NUMERIC(10, 2) DEFAULT 0, -- Desconto específico neste item
    subtotal NUMERIC(10, 2) GENERATED ALWAYS AS ((quantity * unit_sale_price) - discount_amount) STORED,
    
    is_cancelled BOOLEAN DEFAULT FALSE,

    -- Snapshot Fiscal (Lei da Transparência / SPED)
    cfop VARCHAR(4),
    ncm VARCHAR(8),
    tax_snapshot JSONB, -- Guarda ICMS, PIS, COFINS calculados no momento
    notes TEXT, -- "Sem cebola", "Bem passado"
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE CASCADE,
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (batch_id) REFERENCES batches(id)
);

CREATE INDEX IF NOT EXISTS idx_sale_items_validation ON sale_items(sale_id) INCLUDE (subtotal);


-- ============================================================================
-- PAGAMENTOS DE VENDAS 
-- ============================================================================

CREATE TABLE IF NOT EXISTS sale_payments (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    sale_id UUID NOT NULL,
    
    method payment_method_enum NOT NULL,
    amount NUMERIC(10, 2) NOT NULL,
    
    amount_tendered NUMERIC(10, 2),
    change_amount NUMERIC(10, 2) DEFAULT 0,
    installments INTEGER DEFAULT 1,
    card_brand VARCHAR(50),
    auth_code VARCHAR(100),

    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by UUID,
    CONSTRAINT sale_payments_amount_chk CHECK (amount > 0),
    FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL
);

-- ============================================================================
-- LOGS - Registro de eventos do sistema
-- ============================================================================

CREATE TABLE IF NOT EXISTS logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    level VARCHAR(50) NOT NULL,
    message TEXT NOT NULL,
    path TEXT,
    method VARCHAR(10),
    status_code INT,
    stacktrace TEXT,
    metadata JSONB,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_log_level CHECK (level IN ('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'))
);

CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_logs_created_at_1 ON logs (created_at);

-- SELECT cron.schedule(
--     'delete_old_logs',          -- Nome único do job
--     '0 6 * * *',                -- Cron: Minuto 0, Hora 6, Qualquer dia/mês (Diário)
--     $$DELETE FROM logs WHERE created_at < NOW() - INTERVAL '15 days'$$
-- );

ALTER TABLE logs SET (
    autovacuum_vacuum_scale_factor = 0.1,
    toast_tuple_target = 8160
);

-- ============================================================================
-- USER FEEDBACK
-- ============================================================================

CREATE TABLE IF NOT EXISTS user_feedbacks (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id UUID,
    name TEXT,
    email TEXT,
    bug_type TEXT NOT NULL,
    message TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT user_feedbacks_message_length_cstr CHECK ((length(message) <= 512))
);

-- ============================================================================
-- Currencies
-- ============================================================================

CREATE TABLE IF NOT EXISTS currencies (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usd NUMERIC(18, 6) NOT NULL,
    ars NUMERIC(18, 6) NOT NULL,
    eur NUMERIC(18, 6) NOT NULL,    
    clp NUMERIC(18, 6) NOT NULL,
    pyg NUMERIC(18, 6) NOT NULL,
    uyu NUMERIC(18, 6) NOT NULL,    
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP    
);

CREATE INDEX IF NOT EXISTS idx_currencies_created_at_desc ON currencies(created_at DESC);

-- ============================================================================
-- AUDITORIA
-- ============================================================================

-- Tabela de auditoria de operações sensíveis

CREATE TABLE IF NOT EXISTS security_audit_log (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id UUID,
    tenant_id UUID,
    operation TEXT NOT NULL,
    table_name TEXT NOT NULL,
    record_id UUID,
    old_values JSONB,
    new_values JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE SET NULL ON UPDATE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_audit_record_trace ON security_audit_log (table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_user ON security_audit_log (user_id);
CREATE INDEX IF NOT EXISTS idx_audit_created_at_brin ON security_audit_log USING BRIN (created_at);

