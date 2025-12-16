-- ============================================================================
-- ARMAZEM DO NECA - SCHEMA COMPLETO (V2.1)
-- Sistema de gestão para pequeno comércio com bar, lanchonete e mercearia
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "citext";

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
-- CATEGORIAS - Organização hierárquica de produtos
-- ============================================================================

CREATE TABLE IF NOT EXISTS categories (
    id SERIAL PRIMARY KEY,
    name CITEXT NOT NULL,
    parent_category_id INTEGER,    
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT categories_name_length_cstr CHECK ((length(name)) <= 64 AND length(name) >= 3),
    CONSTRAINT categories_name_unique_cstr UNIQUE (name),
    FOREIGN KEY (parent_category_id) REFERENCES categories(id) ON DELETE SET NULL ON UPDATE CASCADE
);

COMMENT ON TABLE categories IS 'Categorias e subcategorias de produtos (ex: Bebidas, Frios, Lanchonete)';
COMMENT ON COLUMN categories.name IS 'Nome da categoria (case-insensitive)';
COMMENT ON COLUMN categories.parent_category_id IS 'Categoria pai para criar hierarquia (NULL = categoria raiz)';

-- ============================================================================
-- FORNECEDORES - Cadastro de fornecedores de produtos
-- ============================================================================

CREATE TABLE IF NOT EXISTS suppliers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name CITEXT NOT NULL,
    cnpj TEXT,
    phone TEXT,
    contact_name TEXT,
    address TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT suppliers_cnpj_length_check CHECK ((length(cnpj) <= 20)),
    CONSTRAINT suppliers_phone_length_check CHECK ((length(phone) = 11)),
    CONSTRAINT suppliers_cnpj_unique UNIQUE (cnpj),
    CONSTRAINT suppliers_name_unique UNIQUE (name)
);

COMMENT ON TABLE suppliers IS 'Cadastro de fornecedores de mercadorias';
COMMENT ON COLUMN suppliers.cnpj IS 'CNPJ do fornecedor (apenas números)';
COMMENT ON COLUMN suppliers.phone IS 'Telefone de contato (11 dígitos com DDD)';
COMMENT ON COLUMN suppliers.contact_name IS 'Nome da pessoa de contato no fornecedor';

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
    cofins_rate NUMERIC(5,2) DEFAULT 0
);

COMMENT ON TABLE tax_groups IS 'Grupos de tributação para facilitar a gestão fiscal de produtos similares';
COMMENT ON COLUMN tax_groups.description IS 'Descrição do grupo (ex: "Bebidas Frias - Monofásico")';
COMMENT ON COLUMN tax_groups.icms_cst IS 'Código de Situação Tributária do ICMS (ex: 060 = cobrado anteriormente)';
COMMENT ON COLUMN tax_groups.pis_cofins_cst IS 'CST para PIS/COFINS (ex: 04 = Monofásico com alíquota zero)';

-- ============================================================================
-- PRODUTOS - Cadastro principal de mercadorias
-- ============================================================================

CREATE TABLE IF NOT EXISTS products (
    -- Identificação
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name CITEXT NOT NULL,
    sku CITEXT UNIQUE NOT NULL,
    description TEXT,
    category_id INTEGER NOT NULL,
    image_url TEXT,
    
    -- Fiscal
    gtin VARCHAR(14),
    ncm VARCHAR(8) NOT NULL DEFAULT '00000000',
    cest VARCHAR(7),
    cfop_default VARCHAR(4) NOT NULL DEFAULT '5102',
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

    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (category_id) REFERENCES categories(id) ON UPDATE CASCADE,
    FOREIGN KEY (tax_group_id) REFERENCES tax_groups(id) ON DELETE SET NULL ON UPDATE CASCADE,

    CONSTRAINT products_name_unique_cstr UNIQUE (name),
    CONSTRAINT products_gtin_unique_cstr UNIQUE (gtin),
    CONSTRAINT products_sale_price_valid_cstr CHECK (sale_price >= purchase_price),
    CONSTRAINT products_sku_chk CHECK ((length(sku) >= 2 AND length(sku) <= 128))
);

COMMENT ON TABLE products IS 'Cadastro principal de produtos do estabelecimento';
COMMENT ON COLUMN products.name IS 'Nome comercial do produto (único no sistema)';
COMMENT ON COLUMN products.sku IS 'Código interno de identificação (Stock Keeping Unit)';
COMMENT ON COLUMN products.gtin IS 'Código de barras EAN-13 ou similar';
COMMENT ON COLUMN products.ncm IS 'Nomenclatura Comum do Mercosul (obrigatório para emissão de NF-e)';
COMMENT ON COLUMN products.cest IS 'Código Especificador da Substituição Tributária (obrigatório para alguns produtos)';
COMMENT ON COLUMN products.cfop_default IS 'CFOP padrão (5102 = Venda de mercadoria adquirida para revenda)';
COMMENT ON COLUMN products.origin IS 'Origem da mercadoria (0=Nacional, 1=Estrangeira-Importação direta, etc)';
COMMENT ON COLUMN products.stock_quantity IS 'Quantidade atual em estoque';
COMMENT ON COLUMN products.min_stock_quantity IS 'Estoque mínimo para alerta de reposição';
COMMENT ON COLUMN products.max_stock_quantity IS 'Estoque máximo recomendado';
COMMENT ON COLUMN products.average_weight IS 'Peso médio para produtos vendidos por unidade mas pesados';
COMMENT ON COLUMN products.profit_margin IS 'Margem de lucro calculada automaticamente em percentual';
COMMENT ON COLUMN products.is_active IS 'Se FALSE, produto não está mais disponível para venda';
COMMENT ON COLUMN products.needs_preparation IS 'TRUE para produtos preparados (receitas), como caipirinhas ou lanches';

-- ============================================================================
-- RECEITAS - Composição de produtos preparados
-- ============================================================================

CREATE TABLE IF NOT EXISTS recipes (
    product_id UUID NOT NULL,
    ingredient_id UUID NOT NULL,
    measure_unit measure_unit_enum NOT NULL DEFAULT 'UN',
    quantity NUMERIC(10, 4) NOT NULL,
    PRIMARY KEY (product_id, ingredient_id),
    FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    FOREIGN KEY (ingredient_id) REFERENCES products(id) ON DELETE CASCADE,
    CONSTRAINT recipes_quantity_valid CHECK (quantity >= 0.0000)
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

COMMENT ON TABLE batches IS 'Controle de lotes de produtos com validade (FIFO/FEFO)';
COMMENT ON COLUMN batches.batch_code IS 'Código do lote do fornecedor';
COMMENT ON COLUMN batches.expiration_date IS 'Data de validade do lote';
COMMENT ON COLUMN batches.quantity IS 'Quantidade de unidades neste lote';

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

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT users_email_unique_cstr UNIQUE (email),
    CONSTRAINT users_cpf_unique_cstr UNIQUE (cpf),
    CONSTRAINT users_valid_cpf_cstr CHECK (cpf ~ '^\d{3}\.\d{3}\.\d{3}-\d{2}$' OR cpf ~ '^\d{11}$'),
    CONSTRAINT users_valid_phone_cstr CHECK (phone ~ '^\d{10,11}$' OR phone ~ '^\(\d{2}\)\s?\d{4,5}-?\d{4}$'),
    CONSTRAINT users_name_length_cstr CHECK ((length(name) <= 256 AND length(name) >= 2)),
    CONSTRAINT users_nickname_length_check CHECK ((length(nickname) <= 256 AND length(nickname) >= 2)),
    CONSTRAINT users_notes_length_check CHECK ((length(notes) <= 512 AND length(notes) >= 2))
);

COMMENT ON TABLE users IS 'Cadastro de usuários do sistema (funcionários e clientes)';
COMMENT ON COLUMN users.password_hash IS 'Hash da senha (apenas para funcionários que acessam o sistema)';
COMMENT ON COLUMN users.credit_limit IS 'Limite de crédito para compras fiadas';
COMMENT ON COLUMN users.invoice_amount IS 'Valor total em aberto (dívidas não pagas)';
COMMENT ON COLUMN users.state_tax_indicator IS 'Indicador fiscal: 1=Contribuinte ICMS, 2=Isento, 9=Não Contribuinte';
COMMENT ON COLUMN users.notes IS 'Observações sobre o usuário (ex: "Sempre paga em dia", "Preferência por cerveja X")';


CREATE TABLE IF NOT EXISTS user_roles (
    user_id UUID NOT NULL,
    role user_role_enum NOT NULL DEFAULT 'CLIENTE',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, role),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- ============================================================================
-- ENDEREÇOS - Endereços de usuários/clientes
-- ============================================================================

CREATE TABLE IF NOT EXISTS user_addresses (
    user_id UUID NOT NULL,
    ibge_city_code VARCHAR(7),
    street TEXT,
    number TEXT,
    neighborhood TEXT,
    zip_code TEXT,
    state CHAR(2),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);

COMMENT ON TABLE user_addresses IS 'Endereços dos usuários (para entregas e emissão de NF-e)';
COMMENT ON COLUMN user_addresses.ibge_city_code IS 'Código IBGE da cidade (ex: 4205407 para Florianópolis/SC)';

-- ============================================================================
-- TOKENS DE SESSÃO - Controle de autenticação
-- ============================================================================

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked BOOLEAN NOT NULL DEFAULT FALSE,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);

COMMENT ON TABLE refresh_tokens IS 'Tokens de refresh para manter sessões de login ativas';
COMMENT ON COLUMN refresh_tokens.revoked IS 'TRUE quando o token é invalidado (logout)';

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
    FOREIGN KEY (changed_by) REFERENCES users(id)
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

    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMP,
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
    FOREIGN KEY (product_id) REFERENCES products(id) ON UPDATE CASCADE ON DELETE SET NULL,
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
    CONSTRAINT positive_amount CHECK (amount_paid > 0)
);

COMMENT ON TABLE tab_payments IS 'Pagamentos realizados para quitar vendas fiadas (a prazo)';
COMMENT ON COLUMN tab_payments.amount_paid IS 'Valor pago neste pagamento parcial';
COMMENT ON COLUMN tab_payments.payment_method IS 'Forma de pagamento utilizada na quitação';
COMMENT ON COLUMN tab_payments.received_by IS 'Funcionário que recebeu o pagamento';

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
-- TRIGGERS
-- ============================================================================

CREATE OR REPLACE TRIGGER trg_products_updated_at
BEFORE UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE OR REPLACE TRIGGER trg_users_updated_at
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();




INSERT INTO categories (name, parent_category_id) VALUES 
    ('Lanchonete & Cozinha', NULL),
    ('Bar & Drinks', NULL),
    ('Bebidas (Varejo)', NULL),
    ('Mercearia', NULL),
    ('Frios e Laticínios', NULL),
    ('Hortifruti', NULL),
    ('Higiene e Limpeza', NULL),
    ('Conveniência', NULL)
ON CONFLICT (name) DO NOTHING;

-- Subcategorias de Lanchonete
INSERT INTO categories (name, parent_category_id) VALUES 
    ('Lanches Tradicionais', (SELECT id FROM categories WHERE name = 'Lanchonete & Cozinha')),
    ('Salgados e Assados',   (SELECT id FROM categories WHERE name = 'Lanchonete & Cozinha')),
    ('Cafeteria',            (SELECT id FROM categories WHERE name = 'Lanchonete & Cozinha'))
ON CONFLICT (name) DO NOTHING;

-- Subcategorias de Bar
INSERT INTO categories (name, parent_category_id) VALUES 
    ('Cervejas (Geladas/Consumo)', (SELECT id FROM categories WHERE name = 'Bar & Drinks')),
    ('Drinks e Coquetéis',         (SELECT id FROM categories WHERE name = 'Bar & Drinks')),
    ('Doses',                      (SELECT id FROM categories WHERE name = 'Bar & Drinks')),
    ('Porções e Petiscos',         (SELECT id FROM categories WHERE name = 'Bar & Drinks'))
ON CONFLICT (name) DO NOTHING;

-- Subcategorias de Bebidas (Varejo)
INSERT INTO categories (name, parent_category_id) VALUES 
    ('Cervejas (Packs/Fardos)', (SELECT id FROM categories WHERE name = 'Bebidas (Varejo)')),
    ('Refrigerantes e Sucos',   (SELECT id FROM categories WHERE name = 'Bebidas (Varejo)')),
    ('Destilados (Garrafas)',   (SELECT id FROM categories WHERE name = 'Bebidas (Varejo)')),
    ('Águas',                   (SELECT id FROM categories WHERE name = 'Bebidas (Varejo)')),
    ('Águas (Galões/Retornáveis)', (SELECT id FROM categories WHERE name = 'Bebidas (Varejo)'))
ON CONFLICT (name) DO NOTHING;

-- Subcategorias de Mercearia
INSERT INTO categories (name, parent_category_id) VALUES 
    ('Alimentos Básicos',     (SELECT id FROM categories WHERE name = 'Mercearia')),
    ('Matinais',              (SELECT id FROM categories WHERE name = 'Mercearia')),
    ('Biscoitos e Doces',     (SELECT id FROM categories WHERE name = 'Mercearia')),
    ('Condimentos e Molhos',  (SELECT id FROM categories WHERE name = 'Mercearia'))
ON CONFLICT (name) DO NOTHING;

-- Subcategorias de Frios
INSERT INTO categories (name, parent_category_id) VALUES 
    ('Fatiados',   (SELECT id FROM categories WHERE name = 'Frios e Laticínios')),
    ('Laticínios', (SELECT id FROM categories WHERE name = 'Frios e Laticínios')),
    ('Embutidos',  (SELECT id FROM categories WHERE name = 'Frios e Laticínios'))
ON CONFLICT (name) DO NOTHING;

-- Subcategorias de Hortifruti
INSERT INTO categories (name, parent_category_id) VALUES 
    ('Frutas',   (SELECT id FROM categories WHERE name = 'Hortifruti')),
    ('Legumes',  (SELECT id FROM categories WHERE name = 'Hortifruti')),
    ('Verduras', (SELECT id FROM categories WHERE name = 'Hortifruti'))
ON CONFLICT (name) DO NOTHING;

-- Subcategorias de Limpeza
INSERT INTO categories (name, parent_category_id) VALUES 
    ('Limpeza Casa',    (SELECT id FROM categories WHERE name = 'Higiene e Limpeza')),
    ('Higiene Pessoal', (SELECT id FROM categories WHERE name = 'Higiene e Limpeza'))
ON CONFLICT (name) DO NOTHING;

-- ============================================================================
-- FUNCTIONS
-- ============================================================================

-- Obtém o ID do usuário (seguro)
CREATE OR REPLACE FUNCTION auth_uid() RETURNS UUID AS $$
DECLARE
    _uid text;
BEGIN
    _uid := current_setting('app.current_user_id', true);
    IF _uid IS NULL OR _uid = '' THEN RETURN NULL; END IF;
    RETURN _uid::UUID;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Obtém a LISTA de roles do usuário
CREATE OR REPLACE FUNCTION auth_roles() RETURNS text[] AS $$
DECLARE
    _roles text;
BEGIN
    _roles := current_setting('app.current_user_role', true);
    IF _roles IS NULL OR _roles = '' THEN RETURN ARRAY[]::text[]; END IF;
    -- Suporta formato array postgres '{ADMIN,CAIXA}' ou csv 'ADMIN,CAIXA'
    IF _roles LIKE '{%}' THEN RETURN _roles::text[]; END IF;
    RETURN string_to_array(_roles, ',');
EXCEPTION WHEN OTHERS THEN RETURN ARRAY[]::text[];
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Verifica se o usuário tem pelo menos um dos papéis listados
CREATE OR REPLACE FUNCTION has_any_role(VARIADIC valid_roles text[]) RETURNS boolean AS $$
BEGIN
    RETURN auth_roles() && valid_roles;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Verifica se um usuário específico tem determinado role
CREATE OR REPLACE FUNCTION user_has_role(target_user_id UUID, check_role text) RETURNS boolean AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM user_roles 
        WHERE user_id = target_user_id 
        AND role::text = check_role
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Verifica se usuário é staff (qualquer role exceto CLIENT)
CREATE OR REPLACE FUNCTION is_staff_user(target_user_id UUID) RETURNS boolean AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM user_roles 
        WHERE user_id = target_user_id 
        AND role::text IN ('ADMIN', 'GERENTE', 'CAIXA', 'ESTOQUISTA', 'CONTADOR')
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================================
-- USERS
-- ============================================================================
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- SELECT: Staff vê todos, Cliente vê só a si mesmo
DROP POLICY IF EXISTS users_select ON users;
CREATE POLICY users_select ON users FOR SELECT TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'ESTOQUISTA', 'CONTADOR')
    OR id = auth_uid()
);

-- INSERT: Admin cria qualquer um. Staff cria APENAS futuros Clientes.
DROP POLICY IF EXISTS users_insert ON users;
CREATE POLICY users_insert ON users FOR INSERT TO PUBLIC
WITH CHECK (
    has_any_role('ADMIN', 'GERENTE', 'CAIXA') -- Validação de que o usuário será CLIENT acontece via trigger
);

-- UPDATE: Admin altera qualquer um. Staff altera APENAS Clientes existentes.
DROP POLICY IF EXISTS users_update ON users;
CREATE POLICY users_update ON users FOR UPDATE TO PUBLIC
USING (
    has_any_role('ADMIN')
    OR (
        has_any_role('GERENTE', 'CAIXA') 
        AND NOT is_staff_user(id) -- Só altera se o alvo NÃO for staff
    )
    -- Cliente pode atualizar apenas alguns campos seus (via trigger)
    OR (
        id = auth_uid() 
        AND NOT has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'ESTOQUISTA', 'CONTADOR')
    )
)
WITH CHECK (
    has_any_role('ADMIN')
    OR (
        has_any_role('GERENTE', 'CAIXA') 
        AND NOT is_staff_user(id)
    )
    OR (
        id = auth_uid()
        AND NOT has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'ESTOQUISTA', 'CONTADOR')
    )
);

-- DELETE: Apenas ADMIN
DROP POLICY IF EXISTS users_delete ON users;
CREATE POLICY users_delete ON users FOR DELETE TO PUBLIC
USING ( has_any_role('ADMIN') );

-- 🆕 TRIGGER: Valida que staff não cria outros staff members
CREATE OR REPLACE FUNCTION validate_user_creation()
RETURNS TRIGGER AS $$
BEGIN
    -- Verifica se quem está criando não é ADMIN
    IF NOT has_any_role('ADMIN') THEN
        -- Verifica se está tentando criar usuário com role de staff
        -- (essa verificação será feita após o INSERT na user_roles)
        -- Por enquanto, apenas permite a criação
        RETURN NEW;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_validate_user_creation ON users;
CREATE TRIGGER trg_validate_user_creation
BEFORE INSERT ON users
FOR EACH ROW EXECUTE FUNCTION validate_user_creation();

-- 🆕 TRIGGER: Cliente só pode atualizar campos não-sensíveis
CREATE OR REPLACE FUNCTION validate_user_self_update()
RETURNS TRIGGER AS $$
BEGIN
    -- Se for cliente atualizando a si mesmo
    IF OLD.id = auth_uid() AND NOT has_any_role('ADMIN', 'GERENTE', 'CAIXA') THEN
        -- Impede alteração de campos críticos
        IF OLD.credit_limit != NEW.credit_limit OR
           OLD.invoice_amount != NEW.invoice_amount OR
           OLD.password_hash IS DISTINCT FROM NEW.password_hash OR
           OLD.cpf IS DISTINCT FROM NEW.cpf OR
           OLD.failed_login_attempts != NEW.failed_login_attempts OR
           OLD.account_locked_until IS DISTINCT FROM NEW.account_locked_until THEN
            RAISE EXCEPTION 'Cliente não pode alterar campos sensíveis';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_validate_user_self_update ON users;
CREATE TRIGGER trg_validate_user_self_update
BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION validate_user_self_update();

-- View para retornar os dados de usuário sem mostrar cpf
CREATE OR REPLACE VIEW users_safe AS
SELECT 
    id, 
    name, 
    nickname, 
    email, 
    phone,
    -- Mascara CPF para outros usuários
    CASE 
        WHEN id = auth_uid() OR has_any_role('ADMIN', 'GERENTE', 'CONTADOR') 
        THEN cpf 
        ELSE CASE 
            WHEN cpf IS NOT NULL 
            THEN '***.' || substring(cpf from 8 for 3) || '.**-**' 
            ELSE NULL 
        END
    END as cpf,
    -- Só mostra crédito para staff e próprio usuário
    CASE 
        WHEN id = auth_uid() OR has_any_role('ADMIN', 'GERENTE', 'CAIXA') 
        THEN credit_limit 
        ELSE NULL 
    END as credit_limit,
    CASE 
        WHEN id = auth_uid() OR has_any_role('ADMIN', 'GERENTE', 'CAIXA') 
        THEN invoice_amount 
        ELSE NULL 
    END as invoice_amount,
    notes,
    state_tax_indicator,
    created_at,
    updated_at,
    last_login_at
FROM users;

-- ============================================================================
-- 2. USER_ROLES
-- ============================================================================

ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;

-- Impede auto-promoção e criação de admin por não-admin
DROP POLICY IF EXISTS user_roles_insert ON user_roles;
CREATE POLICY user_roles_insert ON user_roles FOR INSERT TO PUBLIC
WITH CHECK (
    has_any_role('ADMIN')
    OR (
        has_any_role('GERENTE', 'CAIXA')
        AND role = 'CLIENTE' -- Staff só pode atribuir role CLIENT
        AND user_id != auth_uid() -- Não pode atribuir role a si mesmo
    )
);

-- Atualizar/Deletar roles: Apenas Admin, e não pode modificar próprios roles
DROP POLICY IF EXISTS user_roles_update ON user_roles;
CREATE POLICY user_roles_update ON user_roles FOR UPDATE TO PUBLIC
USING ( 
    has_any_role('ADMIN') 
    AND user_id != auth_uid() -- Impede auto-promoção/auto-remoção
)
WITH CHECK (
    has_any_role('ADMIN')
    AND user_id != auth_uid()
);

DROP POLICY IF EXISTS user_roles_delete ON user_roles;
CREATE POLICY user_roles_delete ON user_roles FOR DELETE TO PUBLIC
USING ( 
    has_any_role('ADMIN')
    AND user_id != auth_uid()
);

-- Leitura permitida para staff ou o próprio dono
DROP POLICY IF EXISTS user_roles_select ON user_roles;
CREATE POLICY user_roles_select ON user_roles FOR SELECT TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE', 'CONTADOR')
    OR user_id = auth_uid()
);

-- 🆕 TRIGGER: Valida criação de roles por não-admins
CREATE OR REPLACE FUNCTION validate_role_assignment()
RETURNS TRIGGER AS $$
BEGIN
    -- Se não é ADMIN tentando criar role de staff
    IF NOT has_any_role('ADMIN') THEN
        IF NEW.role::text IN ('ADMIN', 'GERENTE', 'CAIXA', 'ESTOQUISTA', 'CONTADOR') THEN
            RAISE EXCEPTION 'Apenas ADMIN pode atribuir roles de staff';
        END IF;
        
        -- Impede auto-atribuição
        IF NEW.user_id = auth_uid() THEN
            RAISE EXCEPTION 'Não pode atribuir role a si mesmo';
        END IF;
    ELSE
        -- Mesmo ADMIN não pode se auto-promover
        IF NEW.user_id = auth_uid() AND TG_OP = 'INSERT' THEN
            RAISE EXCEPTION 'ADMIN não pode se auto-atribuir novos roles. Use outro admin.';
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_validate_role_assignment ON user_roles;
CREATE TRIGGER trg_validate_role_assignment
BEFORE INSERT OR UPDATE ON user_roles
FOR EACH ROW EXECUTE FUNCTION validate_role_assignment();

-- 🆕 Impede que último ADMIN seja removido
CREATE OR REPLACE FUNCTION prevent_last_admin_removal()
RETURNS TRIGGER AS $$
DECLARE
    admin_count INTEGER;
BEGIN
    IF OLD.role = 'ADMIN' THEN
        SELECT COUNT(*) INTO admin_count
        FROM user_roles
        WHERE role = 'ADMIN' AND user_id != OLD.user_id;
        
        IF admin_count = 0 THEN
            RAISE EXCEPTION 'Não é possível remover o último ADMIN do sistema';
        END IF;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_prevent_last_admin_removal ON user_roles;
CREATE TRIGGER trg_prevent_last_admin_removal
BEFORE DELETE ON user_roles
FOR EACH ROW EXECUTE FUNCTION prevent_last_admin_removal();

-- ============================================================================
-- 3. USER_ADDRESSES (Endereços)
-- ============================================================================

ALTER TABLE user_addresses ENABLE ROW LEVEL SECURITY;

-- Staff vê endereços para entrega. Dono vê o seu.
DROP POLICY IF EXISTS addresses_select ON user_addresses;
CREATE POLICY addresses_select ON user_addresses FOR SELECT TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'CONTADOR')
    OR user_id = auth_uid()
);

-- Staff gerencia endereços
DROP POLICY IF EXISTS addresses_modify ON user_addresses;
CREATE POLICY addresses_modify ON user_addresses FOR ALL TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'CAIXA') )
WITH CHECK ( has_any_role('ADMIN', 'GERENTE', 'CAIXA') );

-- ============================================================================
-- 4. PRODUCTS
-- ============================================================================

ALTER TABLE products ENABLE ROW LEVEL SECURITY;

-- Visível para todos (ou apenas staff, dependendo da necessidade)
DROP POLICY IF EXISTS products_select ON products;
CREATE POLICY products_select ON products FOR SELECT TO PUBLIC
USING (
    is_active = true -- Todos veem apenas produtos ativos
    OR has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA', 'CAIXA') -- Staff vê inativos
);

-- Gestão: Admin, Gerente, Estoquista
DROP POLICY IF EXISTS products_modify ON products;
CREATE POLICY products_modify ON products FOR ALL TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA') )
WITH CHECK ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA') );

-- TRIGGER: Valida preços e quantidades
CREATE OR REPLACE FUNCTION validate_product_data()
RETURNS TRIGGER AS $$
BEGIN
    -- Valida preços
    IF NEW.sale_price < NEW.purchase_price THEN
        RAISE EXCEPTION 'Preço de venda não pode ser menor que preço de compra';
    END IF;
    
    -- Valida estoque
    IF NEW.stock_quantity < 0 THEN
        RAISE EXCEPTION 'Estoque não pode ser negativo';
    END IF;
    
    IF NEW.min_stock_quantity < 0 OR NEW.max_stock_quantity < 0 THEN
        RAISE EXCEPTION 'Limites de estoque devem ser positivos';
    END IF;
    
    IF NEW.max_stock_quantity > 0 AND NEW.min_stock_quantity > NEW.max_stock_quantity THEN
        RAISE EXCEPTION 'Estoque mínimo não pode ser maior que máximo';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_product_data ON products;
CREATE TRIGGER trg_validate_product_data
BEFORE INSERT OR UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION validate_product_data();


-- ============================================================================
-- 5. CATEGORIES
-- ============================================================================

ALTER TABLE categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS categories_select ON categories;
CREATE POLICY categories_select ON categories FOR SELECT TO PUBLIC
USING (true);

DROP POLICY IF EXISTS categories_modify ON categories;
CREATE POLICY categories_modify ON categories FOR ALL TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA') )
WITH CHECK ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA') );

-- ============================================================================
-- 6. SALES (Vendas) - MELHORADO
-- ============================================================================

ALTER TABLE sales ENABLE ROW LEVEL SECURITY;

-- Ver: Staff vê tudo, Cliente vê as suas
DROP POLICY IF EXISTS sales_select ON sales;
CREATE POLICY sales_select ON sales FOR SELECT TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'CONTADOR', 'ESTOQUISTA')
    OR customer_id = auth_uid()
);

-- Criar: Staff apenas
DROP POLICY IF EXISTS sales_insert ON sales;
CREATE POLICY sales_insert ON sales FOR INSERT TO PUBLIC
WITH CHECK ( 
    has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    AND subtotal >= 0
    AND total_discount >= 0
    AND total_amount >= 0
);

-- Editar: Admin/Gerente total; Caixa apenas se ele criou e está ABERTA
DROP POLICY IF EXISTS sales_update ON sales;
CREATE POLICY sales_update ON sales FOR UPDATE TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE') 
    OR (
        has_any_role('CAIXA') 
        AND salesperson_id = auth_uid() 
        AND status = 'ABERTA'
    )
);

-- Deletar: Admin; Gerente/Caixa apenas se ABERTA
DROP POLICY IF EXISTS sales_delete ON sales;
CREATE POLICY sales_delete ON sales FOR DELETE TO PUBLIC
USING (
    has_any_role('ADMIN')
    OR (
        has_any_role('GERENTE', 'CAIXA') 
        AND status = 'ABERTA'
    )
);

-- 🆕 TRIGGER: Valida totais da venda
CREATE OR REPLACE FUNCTION validate_sale_totals()
RETURNS TRIGGER AS $$
DECLARE
    calculated_subtotal NUMERIC(10,2);
    item_count INTEGER;
BEGIN
    -- Para vendas concluídas, valida totais
    IF NEW.status IN ('CONCLUIDA', 'EM_ENTREGA') THEN
        SELECT COALESCE(SUM(subtotal), 0), COUNT(*)
        INTO calculated_subtotal, item_count
        FROM sale_items WHERE sale_id = NEW.id;
        
        -- Venda deve ter itens
        IF item_count = 0 THEN
            RAISE EXCEPTION 'Venda não pode ser concluída sem itens';
        END IF;
        
        -- Valida subtotal (tolerância de 1 centavo por arredondamento)
        IF ABS(NEW.subtotal - calculated_subtotal) > 0.01 THEN
            RAISE EXCEPTION 'Subtotal inválido: esperado %, recebido %', 
                calculated_subtotal, NEW.subtotal;
        END IF;
        
        -- Valida total_amount
        IF ABS(NEW.total_amount - (NEW.subtotal - COALESCE(NEW.total_discount, 0))) > 0.01 THEN
            RAISE EXCEPTION 'Total inválido: deve ser subtotal - desconto';
        END IF;
        
        -- Desconto não pode ser maior que subtotal
        IF NEW.total_discount > NEW.subtotal THEN
            RAISE EXCEPTION 'Desconto não pode ser maior que subtotal';
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_sale_totals ON sales;
CREATE TRIGGER trg_validate_sale_totals
BEFORE UPDATE ON sales
FOR EACH ROW 
WHEN (NEW.status IN ('CONCLUIDA', 'EM_ENTREGA'))
EXECUTE FUNCTION validate_sale_totals();

-- 🆕 TRIGGER: Valida mudança de status
CREATE OR REPLACE FUNCTION validate_sale_status_change()
RETURNS TRIGGER AS $$
BEGIN
    -- Não pode reabrir venda cancelada
    IF OLD.status = 'CANCELADA' AND NEW.status != 'CANCELADA' THEN
        RAISE EXCEPTION 'Não é possível reabrir venda cancelada';
    END IF;
    
    -- Não pode cancelar venda já concluída (apenas ADMIN)
    IF OLD.status = 'CONCLUIDA' AND NEW.status = 'CANCELADA' THEN
        IF NOT has_any_role('ADMIN', 'GERENTE') THEN
            RAISE EXCEPTION 'Apenas ADMIN/GERENTE pode cancelar venda concluída';
        END IF;
    END IF;
    
    -- Se cancelando, deve ter motivo
    IF NEW.status = 'CANCELADA' AND (NEW.cancellation_reason IS NULL OR NEW.cancellation_reason = '') THEN
        RAISE EXCEPTION 'Motivo de cancelamento é obrigatório';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_sale_status_change ON sales;
CREATE TRIGGER trg_validate_sale_status_change
BEFORE UPDATE ON sales
FOR EACH ROW 
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION validate_sale_status_change();


-- ============================================================================
-- 7. SALE_ITEMS
-- ============================================================================

ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sale_items_select ON sale_items;
CREATE POLICY sale_items_select ON sale_items FOR SELECT TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'CONTADOR', 'ESTOQUISTA')
    OR EXISTS (
        SELECT 1 FROM sales s WHERE s.id = sale_items.sale_id AND s.customer_id = auth_uid()
    )
);

-- 🆕 MELHORADO: Validações adicionais
DROP POLICY IF EXISTS sale_items_insert ON sale_items;
CREATE POLICY sale_items_insert ON sale_items FOR INSERT TO PUBLIC
WITH CHECK (
    has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    AND quantity > 0
    AND quantity <= 10000
    AND unit_sale_price >= 0
    AND EXISTS (
        SELECT 1 FROM sales s 
        WHERE s.id = sale_items.sale_id 
        AND s.status = 'ABERTA'
    )
);

DROP POLICY IF EXISTS sale_items_update ON sale_items;
CREATE POLICY sale_items_update ON sale_items FOR UPDATE TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE')
    OR EXISTS (
        SELECT 1 FROM sales s 
        WHERE s.id = sale_items.sale_id 
        AND s.status = 'ABERTA'
        AND has_any_role('CAIXA')
    )
)
WITH CHECK (
    quantity > 0
    AND quantity <= 10000
    AND unit_sale_price >= 0
);

DROP POLICY IF EXISTS sale_items_delete ON sale_items;
CREATE POLICY sale_items_delete ON sale_items FOR DELETE TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE')
    OR EXISTS (
        SELECT 1 FROM sales s 
        WHERE s.id = sale_items.sale_id 
        AND s.status = 'ABERTA'
        AND has_any_role('CAIXA')
    )
);

-- 🆕 TRIGGER: Valida produto existe e está ativo
CREATE OR REPLACE FUNCTION validate_sale_item()
RETURNS TRIGGER AS $$
DECLARE
    product_active BOOLEAN;
    product_stock NUMERIC(10,3);
BEGIN
    -- Valida produto existe e está ativo
    SELECT is_active, stock_quantity 
    INTO product_active, product_stock
    FROM products WHERE id = NEW.product_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Produto não encontrado';
    END IF;
    
    IF NOT product_active THEN
        RAISE EXCEPTION 'Produto inativo não pode ser vendido';
    END IF;
    
    -- Avisa se estoque insuficiente (não bloqueia, apenas avisa via log)
    IF product_stock < NEW.quantity THEN
        RAISE WARNING 'Estoque insuficiente para produto %. Estoque: %, Vendido: %',
            NEW.product_id, product_stock, NEW.quantity;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_sale_item ON sale_items;
CREATE TRIGGER trg_validate_sale_item
BEFORE INSERT OR UPDATE ON sale_items
FOR EACH ROW EXECUTE FUNCTION validate_sale_item();

-- ============================================================================
-- 8. SALE_PAYMENTS
-- ============================================================================

ALTER TABLE sale_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sale_payments_select ON sale_payments;
CREATE POLICY sale_payments_select ON sale_payments FOR SELECT TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE', 'CONTADOR', 'CAIXA')
    OR EXISTS (
        SELECT 1 FROM sales s WHERE s.id = sale_payments.sale_id AND s.customer_id = auth_uid()
    )
);

-- 🆕 MELHORADO: Validação de valores
DROP POLICY IF EXISTS sale_payments_insert ON sale_payments;
CREATE POLICY sale_payments_insert ON sale_payments FOR INSERT TO PUBLIC
WITH CHECK ( 
    has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    AND total > 0
    AND total <= 1000000 -- Limite de segurança
);

-- Modificar/Deletar: Apenas ADMIN (Segurança financeira)
DROP POLICY IF EXISTS sale_payments_update ON sale_payments;
CREATE POLICY sale_payments_update ON sale_payments FOR UPDATE TO PUBLIC
USING ( has_any_role('ADMIN') )
WITH CHECK ( has_any_role('ADMIN') AND total > 0 );

DROP POLICY IF EXISTS sale_payments_delete ON sale_payments;
CREATE POLICY sale_payments_delete ON sale_payments FOR DELETE TO PUBLIC
USING ( has_any_role('ADMIN') );

-- 🆕 TRIGGER: Valida pagamentos da venda
CREATE OR REPLACE FUNCTION validate_sale_payment()
RETURNS TRIGGER AS $$
DECLARE
    sale_total NUMERIC(10,2);
    payments_total NUMERIC(10,2);
    sale_status sale_status_enum;
BEGIN
    -- Busca informações da venda
    SELECT total_amount, status INTO sale_total, sale_status
    FROM sales WHERE id = NEW.sale_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Venda não encontrada';
    END IF;
    
    -- Não pode adicionar pagamento a venda cancelada
    IF sale_status = 'CANCELADA' THEN
        RAISE EXCEPTION 'Não é possível adicionar pagamento a venda cancelada';
    END IF;
    
    -- Calcula total de pagamentos
    SELECT COALESCE(SUM(total), 0) INTO payments_total
    FROM sale_payments 
    WHERE sale_id = NEW.sale_id 
    AND id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::UUID);
    
    -- Verifica se não excede o total da venda (tolerância de 1 centavo)
    IF (payments_total + NEW.total) > (sale_total + 0.01) THEN
        RAISE EXCEPTION 'Total de pagamentos (%) excede valor da venda (%)',
            (payments_total + NEW.total), sale_total;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_sale_payment ON sale_payments;
CREATE TRIGGER trg_validate_sale_payment
BEFORE INSERT OR UPDATE ON sale_payments
FOR EACH ROW EXECUTE FUNCTION validate_sale_payment();


-- ============================================================================
-- 9. TAB_PAYMENTS 'FIADO'
-- ============================================================================

ALTER TABLE tab_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tab_payments_select ON tab_payments;
CREATE POLICY tab_payments_select ON tab_payments FOR SELECT TO PUBLIC
USING (
    has_any_role('ADMIN', 'GERENTE', 'CONTADOR', 'CAIXA')
    OR EXISTS (
        SELECT 1 FROM sales s WHERE s.id = tab_payments.sale_id AND s.customer_id = auth_uid()
    )
);

DROP POLICY IF EXISTS tab_payments_insert ON tab_payments;
CREATE POLICY tab_payments_insert ON tab_payments FOR INSERT TO PUBLIC
WITH CHECK ( 
    has_any_role('ADMIN', 'GERENTE', 'CAIXA')
    AND amount_paid > 0
    AND amount_paid <= 1000000
);

-- Apenas Admin altera/deleta pagamentos registrados
DROP POLICY IF EXISTS tab_payments_update ON tab_payments;
CREATE POLICY tab_payments_update ON tab_payments FOR UPDATE TO PUBLIC
USING ( has_any_role('ADMIN') )
WITH CHECK ( has_any_role('ADMIN') AND amount_paid > 0 );

DROP POLICY IF EXISTS tab_payments_delete ON tab_payments;
CREATE POLICY tab_payments_delete ON tab_payments FOR DELETE TO PUBLIC
USING ( has_any_role('ADMIN') );

-- ============================================================================
-- 10. STOCK_MOVEMENTS
-- ============================================================================

ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS stock_select ON stock_movements;
CREATE POLICY stock_select ON stock_movements FOR SELECT TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA', 'CONTADOR') );

-- 🆕 MELHORADO: Validação de tipo de movimento por role
DROP POLICY IF EXISTS stock_insert ON stock_movements;
CREATE POLICY stock_insert ON stock_movements FOR INSERT TO PUBLIC
WITH CHECK (
    has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA', 'CAIXA')
    AND (
        -- CAIXA só registra vendas/devoluções
        (NOT has_any_role('CAIXA') OR has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA'))
        OR type IN ('VENDA', 'DEVOLUCAO_VENDA', 'CANCELAMENTO')
    )
);

-- 🆕 TRIGGER: Valida tipo de movimento e sinais de quantidade
CREATE OR REPLACE FUNCTION validate_stock_movement()
RETURNS TRIGGER AS $$
BEGIN
    -- Valida sinal da quantidade baseado no tipo
    CASE NEW.type
        WHEN 'VENDA', 'PERDA', 'CONSUMO_INTERNO', 'DEVOLUCAO_FORNECEDOR' THEN
            IF NEW.quantity >= 0 THEN
                RAISE EXCEPTION 'Movimentação de saída deve ter quantidade negativa';
            END IF;
        WHEN 'COMPRA', 'DEVOLUCAO_VENDA', 'AJUSTE' THEN
            -- AJUSTE pode ser positivo ou negativo
            IF NEW.type != 'AJUSTE' AND NEW.quantity <= 0 THEN
                RAISE EXCEPTION 'Movimentação de entrada deve ter quantidade positiva';
            END IF;
        ELSE
            RAISE EXCEPTION 'Tipo de movimentação inválido';
    END CASE;
    
    -- Valida magnitude (protege contra erros de digitação)
    IF ABS(NEW.quantity) > 10000 THEN
        RAISE WARNING 'Movimentação muito grande: % unidades', ABS(NEW.quantity);
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_validate_stock_movement ON stock_movements;
CREATE TRIGGER trg_validate_stock_movement
BEFORE INSERT ON stock_movements
FOR EACH ROW EXECUTE FUNCTION validate_stock_movement();

-- Histórico imutável para não-admins
DROP POLICY IF EXISTS stock_update ON stock_movements;
CREATE POLICY stock_update ON stock_movements FOR UPDATE TO PUBLIC
USING ( has_any_role('ADMIN') )
WITH CHECK ( has_any_role('ADMIN') );

DROP POLICY IF EXISTS stock_delete ON stock_movements;
CREATE POLICY stock_delete ON stock_movements FOR DELETE TO PUBLIC
USING ( has_any_role('ADMIN') );


-- ============================================================================
-- 11. BATCHES (Lotes de Validade)
-- ============================================================================

ALTER TABLE batches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS batches_select ON batches;
CREATE POLICY batches_select ON batches FOR SELECT TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA', 'CAIXA') );

DROP POLICY IF EXISTS batches_modify ON batches;
CREATE POLICY batches_modify ON batches FOR ALL TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA') )
WITH CHECK ( 
    has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA')
    AND quantity >= 0
    AND expiration_date >= CURRENT_DATE
);

-- 🆕 TRIGGER: Alerta sobre lotes vencidos
CREATE OR REPLACE FUNCTION check_batch_expiration()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.expiration_date < CURRENT_DATE THEN
        RAISE WARNING 'Lote % do produto % está vencido', NEW.batch_code, NEW.product_id;
    ELSIF NEW.expiration_date < CURRENT_DATE + INTERVAL '30 days' THEN
        RAISE NOTICE 'Lote % do produto % vence em menos de 30 dias', NEW.batch_code, NEW.product_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_batch_expiration ON batches;
CREATE TRIGGER trg_check_batch_expiration
BEFORE INSERT OR UPDATE ON batches
FOR EACH ROW EXECUTE FUNCTION check_batch_expiration();

-- ============================================================================
-- 12. SUPPLIERS (Fornecedores)
-- ============================================================================

ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS suppliers_select ON suppliers;
CREATE POLICY suppliers_select ON suppliers FOR SELECT TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA', 'CONTADOR') );

DROP POLICY IF EXISTS suppliers_modify ON suppliers;
CREATE POLICY suppliers_modify ON suppliers FOR ALL TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA') )
WITH CHECK ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA') );


-- ============================================================================
-- 13. TAX_GROUPS (Fiscal)
-- ============================================================================

ALTER TABLE tax_groups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tax_groups_select ON tax_groups;
CREATE POLICY tax_groups_select ON tax_groups FOR SELECT TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'CONTADOR', 'ESTOQUISTA') );

DROP POLICY IF EXISTS tax_groups_modify ON tax_groups;
CREATE POLICY tax_groups_modify ON tax_groups FOR ALL TO PUBLIC
USING ( has_any_role('ADMIN', 'CONTADOR') )
WITH CHECK ( has_any_role('ADMIN', 'CONTADOR') );


-- ============================================================================
-- 14. RECIPES (Receitas)
-- ============================================================================

ALTER TABLE recipes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS recipes_select ON recipes;
CREATE POLICY recipes_select ON recipes FOR SELECT TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'CAIXA', 'ESTOQUISTA') );

DROP POLICY IF EXISTS recipes_modify ON recipes;
CREATE POLICY recipes_modify ON recipes FOR ALL TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE') )
WITH CHECK ( 
    has_any_role('ADMIN', 'GERENTE')
    AND quantity > 0
);

-- 🆕 TRIGGER: Impede receita circular (produto ser ingrediente de si mesmo)
CREATE OR REPLACE FUNCTION prevent_circular_recipe()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.product_id = NEW.ingredient_id THEN
        RAISE EXCEPTION 'Produto não pode ser ingrediente de si mesmo';
    END IF;
    
    -- Verifica ciclos indiretos (A->B, B->A)
    IF EXISTS (
        SELECT 1 FROM recipes 
        WHERE product_id = NEW.ingredient_id 
        AND ingredient_id = NEW.product_id
    ) THEN
        RAISE EXCEPTION 'Receita circular detectada';
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_circular_recipe ON recipes;
CREATE TRIGGER trg_prevent_circular_recipe
BEFORE INSERT OR UPDATE ON recipes
FOR EACH ROW EXECUTE FUNCTION prevent_circular_recipe();


-- ============================================================================
-- 15. PRICE_AUDITS (Auditoria de Preços)
-- ============================================================================

ALTER TABLE price_audits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_select ON price_audits;
CREATE POLICY audit_select ON price_audits FOR SELECT TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE', 'CONTADOR') );

-- Inserido via Trigger, mas staff pode inserir manualmente
DROP POLICY IF EXISTS audit_insert ON price_audits;
CREATE POLICY audit_insert ON price_audits FOR INSERT TO PUBLIC
WITH CHECK ( has_any_role('ADMIN', 'GERENTE', 'ESTOQUISTA') );

-- Histórico imutável
DROP POLICY IF EXISTS audit_update ON price_audits;
CREATE POLICY audit_update ON price_audits FOR UPDATE TO PUBLIC
USING ( has_any_role('ADMIN') )
WITH CHECK ( has_any_role('ADMIN') );

DROP POLICY IF EXISTS audit_delete ON price_audits;
CREATE POLICY audit_delete ON price_audits FOR DELETE TO PUBLIC
USING ( has_any_role('ADMIN') );


-- ============================================================================
-- 16. LOGS (Logs do Sistema) - MELHORADO
-- ============================================================================

ALTER TABLE logs ENABLE ROW LEVEL SECURITY;

-- Ver logs: Apenas gestão
DROP POLICY IF EXISTS logs_select ON logs;
CREATE POLICY logs_select ON logs FOR SELECT TO PUBLIC
USING ( has_any_role('ADMIN', 'GERENTE') );

-- Inserir logs: Qualquer usuário autenticado (sistema registra)
DROP POLICY IF EXISTS logs_insert ON logs;
CREATE POLICY logs_insert ON logs FOR INSERT TO PUBLIC
WITH CHECK ( auth_uid() IS NOT NULL );

-- Apenas ADMIN pode deletar
DROP POLICY IF EXISTS logs_delete ON logs;
CREATE POLICY logs_delete ON logs FOR DELETE TO PUBLIC
USING ( has_any_role('ADMIN') );

-- Logs são imutáveis
DROP POLICY IF EXISTS logs_update ON logs;
CREATE POLICY logs_update ON logs FOR UPDATE TO PUBLIC
USING ( false );

-- 🆕 Função para limpeza automática de logs antigos
CREATE OR REPLACE FUNCTION cleanup_old_logs(days_to_keep INTEGER DEFAULT 90)
RETURNS TABLE(deleted_count BIGINT, oldest_kept TIMESTAMPTZ) AS $$
DECLARE
    _deleted BIGINT;
    _oldest TIMESTAMPTZ;
BEGIN
    -- Deleta logs antigos, mantendo ERRORs e FATALs
    DELETE FROM logs 
    WHERE created_at < NOW() - (days_to_keep || ' days')::INTERVAL
    AND level NOT IN ('ERROR', 'FATAL');
    
    GET DIAGNOSTICS _deleted = ROW_COUNT;
    
    SELECT MIN(created_at) INTO _oldest FROM logs;
    
    RETURN QUERY SELECT _deleted, _oldest;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION cleanup_old_logs IS 'Remove logs com mais de N dias, preservando ERRORs e FATALs. Uso: SELECT * FROM cleanup_old_logs(90);';


-- ============================================================================
-- 17. REFRESH_TOKENS (Autenticação) - MELHORADO
-- ============================================================================

-- 🆕 Adicionar campos de segurança
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS ip_address INET;
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS user_agent TEXT;
ALTER TABLE refresh_tokens ADD COLUMN IF NOT EXISTS expires_at TIMESTAMP;

ALTER TABLE refresh_tokens ENABLE ROW LEVEL SECURITY;

-- Ver: Admin ou dono do token
DROP POLICY IF EXISTS tokens_select ON refresh_tokens;
CREATE POLICY tokens_select ON refresh_tokens FOR SELECT TO PUBLIC
USING (
    has_any_role('ADMIN')
    OR user_id = auth_uid()
);

-- Inserir: O dono do token (no login)
DROP POLICY IF EXISTS tokens_insert ON refresh_tokens;
CREATE POLICY tokens_insert ON refresh_tokens FOR INSERT TO PUBLIC
WITH CHECK ( 
    user_id = auth_uid()
    AND expires_at > NOW()
);

-- Update (Revogar): Admin ou dono
DROP POLICY IF EXISTS tokens_update ON refresh_tokens;
CREATE POLICY tokens_update ON refresh_tokens FOR UPDATE TO PUBLIC
USING (
    has_any_role('ADMIN')
    OR user_id = auth_uid()
)
WITH CHECK (
    has_any_role('ADMIN')
    OR user_id = auth_uid()
);

-- Deletar: Admin ou dono
DROP POLICY IF EXISTS tokens_delete ON refresh_tokens;
CREATE POLICY tokens_delete ON refresh_tokens FOR DELETE TO PUBLIC
USING ( 
    has_any_role('ADMIN')
    OR user_id = auth_uid()
);

-- 🆕 Função para limpar tokens expirados
CREATE OR REPLACE FUNCTION cleanup_expired_tokens()
RETURNS BIGINT AS $$
DECLARE
    deleted_count BIGINT;
BEGIN
    DELETE FROM refresh_tokens 
    WHERE revoked = true 
    OR expires_at < NOW()
    OR created_at < NOW() - INTERVAL '90 days';
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION cleanup_expired_tokens IS 'Remove tokens expirados, revogados ou com mais de 90 dias';


-- ============================================================================
-- 🆕 FUNÇÕES ADMINISTRATIVAS E RELATÓRIOS
-- ============================================================================

-- Relatório de segurança: usuários sem roles
CREATE OR REPLACE FUNCTION report_users_without_roles()
RETURNS TABLE(user_id UUID, user_name TEXT, created_at TIMESTAMP) AS $$
BEGIN
    RETURN QUERY
    SELECT u.id, u.name, u.created_at
    FROM users u
    LEFT JOIN user_roles ur ON u.id = ur.user_id
    WHERE ur.user_id IS NULL
    ORDER BY u.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Relatório: tentativas de login falhadas
CREATE OR REPLACE FUNCTION report_suspicious_login_activity()
RETURNS TABLE(
    user_id UUID, 
    user_name TEXT, 
    failed_attempts INTEGER,
    last_login TIMESTAMP,
    is_locked BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        id, 
        name, 
        failed_login_attempts,
        last_login_at,
        (account_locked_until IS NOT NULL AND account_locked_until > NOW())
    FROM users
    WHERE failed_login_attempts > 3
    OR (account_locked_until IS NOT NULL AND account_locked_until > NOW())
    ORDER BY failed_login_attempts DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Relatório: produtos com estoque negativo (erro de sistema)
CREATE OR REPLACE FUNCTION report_negative_stock()
RETURNS TABLE(
    product_id UUID, 
    product_name CITEXT, 
    stock_quantity NUMERIC,
    last_updated TIMESTAMP
) AS $$
BEGIN
    RETURN QUERY
    SELECT id, name, stock_quantity, updated_at
    FROM products
    WHERE stock_quantity < 0
    ORDER BY stock_quantity ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Relatório: vendas sem pagamento completo
CREATE OR REPLACE FUNCTION report_unpaid_sales()
RETURNS TABLE(
    sale_id UUID,
    customer_id UUID,
    customer_name TEXT,
    total_amount NUMERIC,
    paid_amount NUMERIC,
    pending_amount NUMERIC,
    sale_date TIMESTAMP
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        s.id,
        s.customer_id,
        u.name,
        s.total_amount,
        COALESCE(SUM(sp.total), 0) as paid,
        s.total_amount - COALESCE(SUM(sp.total), 0) as pending,
        s.created_at
    FROM sales s
    LEFT JOIN sale_payments sp ON s.id = sp.sale_id
    LEFT JOIN users u ON s.customer_id = u.id
    WHERE s.status = 'CONCLUIDA'
    GROUP BY s.id, s.customer_id, u.name, s.total_amount, s.created_at
    HAVING s.total_amount - COALESCE(SUM(sp.total), 0) > 0.01
    ORDER BY s.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================================================
-- ÍNDICES PARA PERFORMANCE COM RLS
-- ============================================================================

-- Índices para queries frequentes com RLS
CREATE INDEX IF NOT EXISTS idx_users_id_active ON users(id) WHERE account_locked_until IS NULL;
CREATE INDEX IF NOT EXISTS idx_sales_customer_status ON sales(customer_id, status);
CREATE INDEX IF NOT EXISTS idx_sales_salesperson_status ON sales(salesperson_id, status);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale_id ON sale_items(sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_payments_sale_id ON sale_payments(sale_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_product_date ON stock_movements(product_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_products_active ON products(is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_logs_level_date ON logs(level, created_at DESC);


-- ============================================================================
-- 🆕 VIEWS ÚTEIS PARA RELATÓRIOS (COM RLS AUTOMÁTICO)
-- ============================================================================

-- View: Vendas com informações completas
CREATE OR REPLACE VIEW sales_complete AS
SELECT 
    s.id,
    s.total_amount,
    s.status,
    s.created_at,
    s.finished_at,
    u_seller.name as salesperson_name,
    u_customer.name as customer_name,
    COUNT(si.id) as items_count,
    COALESCE(SUM(sp.total), 0) as paid_amount,
    s.total_amount - COALESCE(SUM(sp.total), 0) as pending_amount
FROM sales s
LEFT JOIN users u_seller ON s.salesperson_id = u_seller.id
LEFT JOIN users u_customer ON s.customer_id = u_customer.id
LEFT JOIN sale_items si ON s.id = si.sale_id
LEFT JOIN sale_payments sp ON s.id = sp.sale_id
GROUP BY s.id, u_seller.name, u_customer.name;

-- View: Produtos com estoque baixo
CREATE OR REPLACE VIEW products_low_stock AS
SELECT 
    p.id,
    p.name,
    p.stock_quantity,
    p.min_stock_quantity,
    p.min_stock_quantity - p.stock_quantity as reorder_quantity,
    c.name as category_name
FROM products p
JOIN categories c ON p.category_id = c.id
WHERE p.is_active = true
AND p.stock_quantity <= p.min_stock_quantity
ORDER BY (p.min_stock_quantity - p.stock_quantity) DESC;


-- ============================================================================
-- CONFIGURAÇÕES
-- ============================================================================


-- === PRODUTOS ===
CREATE INDEX IF NOT EXISTS idx_products_name ON products USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_products_sku ON products(sku);
CREATE INDEX IF NOT EXISTS idx_products_gtin ON products(gtin);
CREATE INDEX IF NOT EXISTS idx_products_category ON products(category_id);
CREATE INDEX IF NOT EXISTS idx_products_active ON products(is_active) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_products_low_stock ON products(stock_quantity, min_stock_quantity) 
    WHERE stock_quantity <= min_stock_quantity AND is_active = TRUE;

COMMENT ON INDEX idx_products_name IS 'Busca textual rápida por nome de produto (trigram)';
COMMENT ON INDEX idx_products_low_stock IS 'Identifica produtos com estoque baixo';

-- === USUÁRIOS ===
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_cpf ON users(cpf);
CREATE INDEX IF NOT EXISTS idx_users_name ON users USING gin(name gin_trgm_ops);


-- === VENDAS ===
CREATE INDEX IF NOT EXISTS idx_sales_status ON sales(status);
CREATE INDEX IF NOT EXISTS idx_sales_customer ON sales(customer_id);
CREATE INDEX IF NOT EXISTS idx_sales_salesperson ON sales(salesperson_id);
CREATE INDEX IF NOT EXISTS idx_sales_created_at ON sales(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sales_finished_at ON sales(finished_at DESC) WHERE finished_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sales_open ON sales(status) WHERE status = 'ABERTA';

COMMENT ON INDEX idx_sales_open IS 'Vendas em andamento';

-- === ITENS DE VENDA ===
CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items(sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items(product_id);

-- === PAGAMENTOS ===
CREATE INDEX IF NOT EXISTS idx_sale_payments_sale ON sale_payments(sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_payments_method ON sale_payments(method);
CREATE INDEX IF NOT EXISTS idx_sale_payments_created ON sale_payments(created_at DESC);

-- === MOVIMENTAÇÃO DE ESTOQUE ===
CREATE INDEX IF NOT EXISTS idx_stock_movements_product ON stock_movements(product_id);
CREATE INDEX IF NOT EXISTS idx_stock_movements_type ON stock_movements(type);
CREATE INDEX IF NOT EXISTS idx_stock_movements_created ON stock_movements(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stock_movements_reference ON stock_movements(reference_id);

-- === LOTES ===
CREATE INDEX IF NOT EXISTS idx_batches_product ON batches(product_id);
CREATE INDEX IF NOT EXISTS idx_batches_expiration ON batches(expiration_date);

-- === CATEGORIAS ===
CREATE INDEX IF NOT EXISTS idx_categories_parent ON categories(parent_category_id);

-- === AUDITORIA ===
CREATE INDEX IF NOT EXISTS idx_price_audits_product ON price_audits(product_id);
CREATE INDEX IF NOT EXISTS idx_price_audits_changed_at ON price_audits(changed_at DESC);

-- === LOGS ===
CREATE INDEX IF NOT EXISTS idx_logs_level ON logs(level);
CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_logs_metadata ON logs USING gin(metadata);

-- === PAGAMENTOS FIADO ===
CREATE INDEX IF NOT EXISTS idx_tab_payments_sale ON tab_payments(sale_id);
CREATE INDEX IF NOT EXISTS idx_tab_payments_created ON tab_payments(created_at DESC);