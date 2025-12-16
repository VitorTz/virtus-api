-- ============================================================================
-- SCMG - SCHEMA COMPLETO (V2.1)
-- Sistema de gestão para pequeno comércio com bar, lanchonete e mercearia
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "citext";

-- ============================================================================
-- API USER
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'app_runtime') THEN
        CREATE ROLE app_runtime NOLOGIN;
    END IF;
END
$$;

GRANT app_runtime TO postgres;

GRANT USAGE ON SCHEMA public TO app_runtime;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO app_runtime;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO app_runtime;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO app_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO app_runtime;

-- ============================================================================
-- ENUMS - Tipos enumerados para padronização de dados
-- ============================================================================

DO $$ BEGIN
    -- Métodos de pagamento aceitos no estabelecimento
    CREATE TYPE payment_method_enum AS ENUM (
        'DINHEIRO',
        'CREDITO',
        'DEBITO',
        'PIX',
        'FIADO-EM-ABERTO',
        'FIADO-PAGO-PARCIAL',
        'FIADO-QUITADO',
        'VALE_ALIMENTACAO'        
    );
    
    -- Tipos de movimentação de estoque
    CREATE TYPE stock_movement_enum AS ENUM (
        'VENDA', 
        'COMPRA', 
        'DEVOLUCAO_VENDA', 
        'DEVOLUCAO_FORNECEDOR', 
        'PERDA', 
        'AJUSTE', 
        'CONSUMO_INTERNO', 
        'CANCELAMENTO'
    );
    
    -- Papéis/funções dos usuários no sistema
    CREATE TYPE user_role_enum AS ENUM (
        'ADMIN',
        'CAIXA', 
        'GERENTE', 
        'CLIENTE',
        'ESTOQUISTA',
        'CONTADOR'
    );
    
    -- Status possíveis de uma venda
    CREATE TYPE sale_status_enum AS ENUM (
        'ABERTA', 
        'CONCLUIDA', 
        'CANCELADA', 
        'EM_ENTREGA'        
    );
    
    -- Unidades de medida para produtos
    CREATE TYPE measure_unit_enum AS ENUM (
        'UN', 
        'KG', 
        'L', 
        'CX'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- ============================================================================
-- FUNCTIONS - Funções auxiliares do banco de dados
-- ============================================================================

-- Atualiza automaticamente o campo updated_at quando um registro é modificado
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';


-- ============================================================================
-- CNPJS
-- ============================================================================

CREATE TABLE IF NOT EXISTS cnpjs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cnpj TEXT NOT NULL,
    data JSONB NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT companies_unique_cnpj UNIQUE (cnpj)
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
    CONSTRAINT tenants_unique_cnpj UNIQUE (cnpj)
);


-- ============================================================================
-- CATEGORIES - Organização hierárquica de produtos
-- ============================================================================
CREATE TABLE IF NOT EXISTS categories (
    id SERIAL PRIMARY KEY,
    name CITEXT NOT NULL,
    parent_category_id INTEGER,    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tenant_id UUID NOT NULL,
    CONSTRAINT categories_name_length_cstr CHECK (length(name) <= 64 AND length(name) >= 3),
    CONSTRAINT categories_name_unique_cstr UNIQUE (name, tenant_id),
    FOREIGN KEY (parent_category_id) REFERENCES categories(id) ON DELETE SET NULL ON UPDATE CASCADE,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE
);


-- ============================================================================
-- SUPPLIERS - Cadastro de fornecedores de produtos
-- ============================================================================

CREATE TABLE IF NOT EXISTS suppliers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name CITEXT NOT NULL,
    cnpj TEXT,
    phone TEXT,
    contact_name TEXT,
    address TEXT,
    tenant_id UUID NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT suppliers_cnpj_length_check CHECK ((length(cnpj) <= 20)),
    CONSTRAINT suppliers_phone_length_check CHECK ((length(phone) = 11)),
    CONSTRAINT suppliers_cnpj_unique UNIQUE (cnpj, tenant_id),
    CONSTRAINT suppliers_name_unique UNIQUE (name, tenant_id),
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE
);


-- ============================================================================
-- TRIBUTAÇÃO - Grupos fiscais e impostos
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
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE
);

-- ============================================================================
-- PRODUTOS - Cadastro principal de mercadorias
-- ============================================================================

CREATE TABLE IF NOT EXISTS products (
    -- Identificação
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name CITEXT NOT NULL,
    sku CITEXT NOT NULL,
    description TEXT,
    category_id INTEGER NOT NULL,
    image_url TEXT,
    
    -- Fiscal
    gtin VARCHAR(14),
    ncm VARCHAR(8),
    cest VARCHAR(7),
    cfop_default VARCHAR(4),
    origin CHAR(1) NOT NULL DEFAULT '0',
    tax_group_id UUID,

    -- Estoque
    stock_quantity NUMERIC(10, 3) NOT NULL DEFAULT 0,
    min_stock_quantity NUMERIC(10, 3) NOT NULL DEFAULT 0,
    max_stock_quantity NUMERIC(10, 3) NOT NULL DEFAULT 0,
    average_weight NUMERIC(10, 4) NOT NULL DEFAULT 0.0,
    
    -- Preços e Margem
    purchase_price NUMERIC(10, 2) NOT NULL DEFAULT 0,
    sale_price NUMERIC(10, 2) NOT NULL DEFAULT 0,
    profit_margin NUMERIC(10, 2) GENERATED ALWAYS AS (
        CASE WHEN purchase_price > 0 
        THEN ((sale_price - purchase_price) / purchase_price * 100) 
        ELSE 0 END
    ) STORED,
    measure_unit measure_unit_enum NOT NULL DEFAULT 'UN',
    
    -- Status
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    needs_preparation BOOLEAN NOT NULL DEFAULT FALSE,

    tenant_id UUID NOT NULL,

    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (category_id) REFERENCES categories(id) ON UPDATE CASCADE,
    FOREIGN KEY (tax_group_id) REFERENCES tax_groups(id) ON DELETE SET NULL ON UPDATE CASCADE,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT products_name_unique_cstr UNIQUE (name, tenant_id),
    CONSTRAINT products_gtin_unique_cstr UNIQUE (gtin, tenant_id),
    CONSTRAINT products_unique_sku_cstr UNIQUE (sku, tenant_id),
    CONSTRAINT products_sku_chk CHECK ((length(sku) >= 2 AND length(sku) <= 128))
);

COMMENT ON COLUMN products.needs_preparation IS 'TRUE para produtos preparados (receitas), como caipirinhas ou lanches';

-- ============================================================================
-- RECEITAS - Composição de produtos preparados
-- ============================================================================

CREATE TABLE IF NOT EXISTS recipes (
    product_id UUID NOT NULL,
    ingredient_id UUID NOT NULL,
    quantity NUMERIC(10, 4) NOT NULL,
    PRIMARY KEY (product_id, ingredient_id),
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (ingredient_id) REFERENCES products(id) ON DELETE CASCADE,
    CONSTRAINT recipes_quantity_valid CHECK (quantity > 0.0000)
);

COMMENT ON TABLE recipes IS 'Receitas de produtos preparados (ex: caipirinha = limão + cachaça + açúcar)';
COMMENT ON COLUMN recipes.product_id IS 'Produto final que será preparado';
COMMENT ON COLUMN recipes.ingredient_id IS 'Ingrediente necessário (também deve ser um produto cadastrado)';
COMMENT ON COLUMN recipes.quantity IS 'Quantidade do ingrediente necessária por unidade do produto final';

-- ============================================================================
-- LOTES - Controle de validade e rastreabilidade
-- ============================================================================

CREATE TABLE IF NOT EXISTS batches (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL,
    batch_code TEXT,
    expiration_date DATE NOT NULL,
    quantity NUMERIC(10, 3) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    CONSTRAINT batches_batch_code_length_cstr CHECK (length(batch_code) <= 64),
    CONSTRAINT batches_quantity_valid CHECK (quantity >= 0.000)
);

-- ============================================================================
-- USUÁRIOS - Cadastro de funcionários e clientes
-- ============================================================================


CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    nickname TEXT,
    email TEXT,
    phone TEXT,
    cpf VARCHAR(14),
    notes TEXT,
    password_hash TEXT,

    -- Controle de crédito para vendas fiadas
    credit_limit NUMERIC(10, 2) NOT NULL DEFAULT 0,
    invoice_amount NUMERIC(10, 2) NOT NULL DEFAULT 0,

    state_tax_indicator SMALLINT DEFAULT 9,

    last_login_at TIMESTAMP,
    failed_login_attempts INTEGER DEFAULT 0,
    account_locked_until TIMESTAMP,

    tenant_id UUID NOT NULL,

    created_by UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT users_email_unique_cstr UNIQUE (email, tenant_id),
    CONSTRAINT users_cpf_unique_cstr UNIQUE (cpf, tenant_id),
    CONSTRAINT users_valid_cpf_cstr
        CHECK (
            cpf IS NULL
            OR cpf ~ '^\d{3}\.\d{3}\.\d{3}-\d{2}$'
            OR cpf ~ '^\d{11}$'
    ),
    CONSTRAINT users_valid_phone_cstr
        CHECK (
            phone IS NULL
            OR phone ~ '^\d{10,11}$'
            OR phone ~ '^\(\d{2}\)\s?\d{4,5}-?\d{4}$'
    ),
    CONSTRAINT users_name_length_cstr CHECK (length(name) BETWEEN 2 AND 256),
    CONSTRAINT users_nickname_length_cstr CHECK (nickname IS NULL OR (length(nickname) BETWEEN 2 AND 256)),
    CONSTRAINT users_notes_length_cstr CHECK (notes IS NULL OR (length(notes) BETWEEN 2 AND 256))
);

COMMENT ON TABLE users IS 'Cadastro de usuários do sistema (funcionários e clientes)';
COMMENT ON COLUMN users.password_hash IS 'Hash da senha (apenas para funcionários que acessam o sistema)';
COMMENT ON COLUMN users.credit_limit IS 'Limite de crédito para compras fiadas';
COMMENT ON COLUMN users.invoice_amount IS 'Valor total em aberto (dívidas não pagas)';
COMMENT ON COLUMN users.state_tax_indicator IS 'Indicador fiscal: 1=Contribuinte ICMS, 2=Isento, 9=Não Contribuinte';
COMMENT ON COLUMN users.notes IS 'Observações sobre o usuário (ex: "Sempre paga em dia", "Preferência por cerveja X")';


CREATE TABLE IF NOT EXISTS user_roles (
    id UUID NOT NULL,
    role user_role_enum NOT NULL DEFAULT 'CLIENTE',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, role),
    FOREIGN KEY (id) REFERENCES users(id) ON DELETE CASCADE
);

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


CREATE TABLE IF NOT EXISTS user_addresses (
    user_id UUID NOT NULL,
    cep TEXT NOT NULL,
    descr TEXT,
    number TEXT,
    PRIMARY KEY (user_id, cep),    
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (cep) REFERENCES addresses(cep) ON DELETE CASCADE ON UPDATE CASCADE
);

-- ============================================================================
-- TOKENS DE SESSÃO - Controle de autenticação
-- ============================================================================

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    token_hash TEXT NOT NULL, -- Hash do token enviado ao cliente
    device_hash TEXT NOT NULL, -- O Fingerprint do hardware (Segurança Extra)
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    revoked BOOLEAN DEFAULT FALSE,
    family_id UUID NOT NULL,
    replaced_by UUID REFERENCES refresh_tokens(id),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_refresh_token_family ON refresh_tokens(family_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_active_family ON refresh_tokens(family_id) WHERE revoked = FALSE;
CREATE INDEX IF NOT EXISTS idx_refresh_token_hash ON refresh_tokens(token_hash);

-- ============================================================================
-- AUDITORIA DE PREÇOS - Histórico de alterações de preços
-- ============================================================================

CREATE TABLE IF NOT EXISTS price_audits (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL,
    old_purchase_price NUMERIC(10, 2),
    new_purchase_price NUMERIC(10, 2),
    old_sale_price NUMERIC(10, 2),
    new_sale_price NUMERIC(10, 2),
    changed_by UUID,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES products(id),
    FOREIGN KEY (changed_by) REFERENCES users(id),
    FOREIGN KEY (changed_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
);

COMMENT ON TABLE price_audits IS 'Histórico de alterações de preços de produtos';
COMMENT ON COLUMN price_audits.changed_by IS 'Usuário que realizou a alteração de preço';

-- ============================================================================
-- MOVIMENTAÇÃO DE ESTOQUE - Todas as entradas e saídas
-- ============================================================================

CREATE TABLE IF NOT EXISTS stock_movements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL,
    type stock_movement_enum NOT NULL,
    quantity NUMERIC(10, 3) NOT NULL,
    reference_id UUID,
    reason TEXT,
    created_by UUID,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE CASCADE,
    FOREIGN KEY (created_by) REFERENCES users(id) ON UPDATE CASCADE ON DELETE SET NULL
);

COMMENT ON TABLE stock_movements IS 'Registro de todas as movimentações de estoque (entradas e saídas)';
COMMENT ON COLUMN stock_movements.type IS 'Tipo: VENDA, COMPRA, DEVOLUCAO, PERDA, AJUSTE, etc';
COMMENT ON COLUMN stock_movements.quantity IS 'Quantidade movimentada (positivo=entrada, negativo=saída)';
COMMENT ON COLUMN stock_movements.reference_id IS 'ID da venda/compra relacionada (se aplicável)';
COMMENT ON COLUMN stock_movements.reason IS 'Motivo da movimentação (ex: "Venda #123", "Produto vencido")';

-- ============================================================================
-- VENDAS - Cabeçalho das vendas
-- ============================================================================

CREATE TABLE IF NOT EXISTS sales (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    subtotal NUMERIC(10, 2) NOT NULL DEFAULT 0,
    total_discount NUMERIC(10, 2) DEFAULT 0,
    total_amount NUMERIC(10, 2) NOT NULL DEFAULT 0,
    status sale_status_enum DEFAULT 'ABERTA',

    salesperson_id UUID,
    customer_id UUID,
    
    cancelled_by UUID,
    cancelled_at TIMESTAMP,
    cancellation_reason TEXT,

    tenant_id UUID NOT NULL,

    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMP,
    FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (salesperson_id) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    FOREIGN KEY (customer_id) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    FOREIGN KEY (cancelled_by) REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
);

COMMENT ON TABLE sales IS 'Cabeçalho das vendas realizadas';
COMMENT ON COLUMN sales.subtotal IS 'Soma dos itens antes de descontos';
COMMENT ON COLUMN sales.total_discount IS 'Desconto total aplicado na venda';
COMMENT ON COLUMN sales.total_amount IS 'Valor final da venda (subtotal - desconto)';
COMMENT ON COLUMN sales.status IS 'Status: ABERTA, CONCLUIDA, CANCELADA, EM_ENTREGA';
COMMENT ON COLUMN sales.salesperson_id IS 'Funcionário que realizou a venda';
COMMENT ON COLUMN sales.customer_id IS 'Cliente que realizou a compra (opcional)';
COMMENT ON COLUMN sales.finished_at IS 'Data/hora da conclusão da venda';

-- ============================================================================
-- ITENS DE VENDA - Produtos vendidos em cada venda
-- ============================================================================

CREATE TABLE IF NOT EXISTS sale_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sale_id UUID NOT NULL,
    product_id UUID NOT NULL,
    quantity NUMERIC(10, 3) NOT NULL,
    unit_sale_price NUMERIC(10, 2) NOT NULL,
    unit_cost_price NUMERIC(10, 2),
    subtotal NUMERIC(10, 2) GENERATED ALWAYS AS (quantity * unit_sale_price) STORED,
    CONSTRAINT sale_items_greater_than_zero_cstr CHECK (quantity > 0),
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE CASCADE ON UPDATE CASCADE
);

COMMENT ON TABLE sale_items IS 'Itens individuais de cada venda';
COMMENT ON COLUMN sale_items.unit_sale_price IS 'Preço de venda unitário no momento da venda (congelado)';
COMMENT ON COLUMN sale_items.unit_cost_price IS 'Custo unitário no momento da venda (para cálculo de lucro real)';
COMMENT ON COLUMN sale_items.subtotal IS 'Valor total do item (quantidade × preço unitário)';

-- ============================================================================
-- PAGAMENTOS DE VENDAS - Formas de pagamento utilizadas
-- ============================================================================

CREATE TABLE IF NOT EXISTS sale_payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sale_id UUID NOT NULL,
    method payment_method_enum NOT NULL,
    total NUMERIC(10, 2) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (sale_id) REFERENCES sales(id) ON DELETE CASCADE ON UPDATE CASCADE
);

COMMENT ON TABLE sale_payments IS 'Formas de pagamento utilizadas em cada venda (pode haver múltiplas)';
COMMENT ON COLUMN sale_payments.method IS 'Método: DINHEIRO, CREDITO, DEBITO, PIX, FIADO, etc';
COMMENT ON COLUMN sale_payments.total IS 'Valor pago através deste método';

-- ============================================================================
-- PAGAMENTOS DE FIADO - Quitação de dívidas
-- ============================================================================

CREATE TABLE IF NOT EXISTS tab_payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sale_id UUID NOT NULL,
    amount_paid NUMERIC(10, 2) NOT NULL,
    payment_method payment_method_enum NOT NULL,
    received_by UUID,
    observation TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (sale_id) REFERENCES sales(id),
    FOREIGN KEY (received_by) REFERENCES users(id),
    CONSTRAINT tab_payments_positive_amount CHECK (amount_paid > 0)
);

COMMENT ON TABLE tab_payments IS 'Pagamentos realizados para quitar vendas fiadas (a prazo)';
COMMENT ON COLUMN tab_payments.amount_paid IS 'Valor pago neste pagamento parcial';
COMMENT ON COLUMN tab_payments.payment_method IS 'Forma de pagamento utilizada na quitação';
COMMENT ON COLUMN tab_payments.received_by IS 'Funcionário que recebeu o pagamento';


CREATE OR REPLACE FUNCTION calculate_user_debt_balance(target_user_id UUID) 
RETURNS NUMERIC AS $$
DECLARE
    total_debt NUMERIC(10, 2);
    total_paid NUMERIC(10, 2);
BEGIN
    -- 1. Soma tudo que foi vendido como FIADO (apenas vendas não canceladas)
    SELECT COALESCE(SUM(sp.total), 0)
    INTO total_debt
    FROM sale_payments sp
    JOIN sales s ON s.id = sp.sale_id
    WHERE s.customer_id = target_user_id
      AND s.status != 'CANCELADA'
      AND sp.method IN ('FIADO-EM-ABERTO', 'FIADO-PAGO-PARCIAL');

    -- 2. Soma todos os pagamentos de dívida (tab_payments) já realizados
    SELECT COALESCE(SUM(tp.amount_paid), 0)
    INTO total_paid
    FROM tab_payments tp
    JOIN sales s ON s.id = tp.sale_id
    WHERE s.customer_id = target_user_id;

    -- Retorna o saldo (Dívida - Pago)
    RETURN total_debt - total_paid;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION trg_update_user_invoice_amount()
RETURNS TRIGGER AS $$
DECLARE
    affected_customer_id UUID;
BEGIN
    -- Descobre quem é o cliente afetado dependendo da tabela de origem
    
    -- Caso 1: Movimentação em Pagamentos da Venda (sale_payments)
    IF TG_TABLE_NAME = 'sale_payments' THEN
        SELECT customer_id INTO affected_customer_id FROM sales WHERE id = COALESCE(NEW.sale_id, OLD.sale_id);
    
    -- Caso 2: Pagamento de Dívida (tab_payments)
    ELSIF TG_TABLE_NAME = 'tab_payments' THEN
        SELECT customer_id INTO affected_customer_id FROM sales WHERE id = COALESCE(NEW.sale_id, OLD.sale_id);
    
    -- Caso 3: Cancelamento de Venda (sales)
    ELSIF TG_TABLE_NAME = 'sales' THEN
        affected_customer_id := COALESCE(NEW.customer_id, OLD.customer_id);
    END IF;

    -- Se existe um cliente vinculado, atualiza o saldo dele
    IF affected_customer_id IS NOT NULL THEN
        UPDATE users 
        SET invoice_amount = calculate_user_debt_balance(affected_customer_id),
            updated_at = CURRENT_TIMESTAMP
        WHERE id = affected_customer_id;
    END IF;

    RETURN NULL; -- Trigger do tipo AFTER não precisa retornar NEW
END;
$$ LANGUAGE plpgsql;

-- 1. Monitora quando uma venda é feita no Fiado (ou editada)
CREATE OR REPLACE TRIGGER trg_audit_debt_sale_payments
AFTER INSERT OR UPDATE OR DELETE ON sale_payments
FOR EACH ROW EXECUTE FUNCTION trg_update_user_invoice_amount();

-- 2. Monitora quando o cliente paga a dívida
CREATE OR REPLACE TRIGGER trg_audit_debt_tab_payments
AFTER INSERT OR UPDATE OR DELETE ON tab_payments
FOR EACH ROW EXECUTE FUNCTION trg_update_user_invoice_amount();

-- 3. Monitora se uma venda foi cancelada (para remover a dívida)
CREATE OR REPLACE TRIGGER trg_audit_debt_sales_status
AFTER UPDATE OF status, customer_id ON sales
FOR EACH ROW EXECUTE FUNCTION trg_update_user_invoice_amount();


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

COMMENT ON TABLE logs IS 'Registro de logs do sistema para auditoria e debugging';
COMMENT ON COLUMN logs.level IS 'Nível de severidade do log';
COMMENT ON COLUMN logs.metadata IS 'Dados adicionais em formato JSON';


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
-- Currency
-- ============================================================================

CREATE TABLE IF NOT EXISTS currency_values (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usd NUMERIC(18, 6) NOT NULL,
    ars NUMERIC(18, 6) NOT NULL,
    eur NUMERIC(18, 6) NOT NULL,    
    clp NUMERIC(18, 6) NOT NULL,
    pyg NUMERIC(18, 6) NOT NULL,
    uyu NUMERIC(18, 6) NOT NULL,    
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP    
);

-- Simple B-tree index (best for ranges, ORDER BY, comparisons)
CREATE INDEX IF NOT EXISTS idx_currency_values_created_at ON currency_values(created_at);

-- Optional: descending index if you often query “latest first”
CREATE INDEX IF NOT EXISTS idx_currency_values_created_at_desc ON currency_values(created_at DESC);


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


-- ============================================================================
-- TRIGGERS
-- ============================================================================

CREATE OR REPLACE TRIGGER trg_products_updated_at
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE OR REPLACE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
