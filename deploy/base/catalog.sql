CREATE TABLE IF NOT EXISTS products (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sku VARCHAR(32) NOT NULL UNIQUE,
    name VARCHAR(120) NOT NULL,
    description VARCHAR(500) NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (price >= 0)
);

INSERT IGNORE INTO products (sku, name, description, price) VALUES
    ('ST-001', 'Cotton Tote Bag', 'Reusable natural cotton shopping bag.', 3.49),
    ('ST-002', 'Wooden Pencil Set', 'Pack of six graphite pencils.', 4.25),
    ('ST-003', 'Ceramic Mug', 'Everyday 350 ml stoneware mug.', 5.99),
    ('ST-004', 'Pocket Notebook', 'A6 ruled notebook with 96 pages.', 6.50),
    ('ST-005', 'Stainless Water Bottle', 'Reusable 500 ml bottle.', 8.75),
    ('ST-006', 'Canvas Apron', 'Durable cotton canvas kitchen apron.', 11.25),
    ('ST-007', 'Desk Plant', 'Small low-maintenance indoor plant.', 12.99),
    ('ST-008', 'Wool Blend Scarf', 'Soft midweight scarf for cool weather.', 15.50),
    ('ST-009', 'Insulated Lunch Box', 'Compact lunch box with thermal lining.', 18.00),
    ('ST-010', 'Wireless Mouse', 'Compact wireless mouse with USB receiver.', 21.99),
    ('ST-011', 'Table Lamp', 'Adjustable LED desk lamp.', 28.50),
    ('ST-012', 'Travel Backpack', 'Lightweight 20-liter day backpack.', 39.95);
