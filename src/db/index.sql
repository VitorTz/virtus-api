

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