-- =====================================================================
-- Arquivo 04: Dados de demonstração (seed)
-- Popula o estoque com produtos e um histórico de movimentações
-- para que o agente tenha dados ao ser testado.
-- Execute APÓS os arquivos 01, 02 e 03.
-- =====================================================================

-- Produtos iniciais
select estoque_ia.cadastrar_produto('{"nome":"Teclado Mecânico","preco":199.90,"quantidade":15,"categoria":"Periféricos","estoque_minimo":10}');
select estoque_ia.cadastrar_produto('{"nome":"Headset Gamer","preco":349.90,"quantidade":25,"categoria":"Periféricos","estoque_minimo":8}');
select estoque_ia.cadastrar_produto('{"nome":"Monitor 24 polegadas","preco":899.00,"quantidade":8,"categoria":"Monitores","estoque_minimo":10}');
select estoque_ia.cadastrar_produto('{"nome":"Cadeira Gamer","preco":1200.00,"quantidade":3,"categoria":"Mobiliário","estoque_minimo":5}');
select estoque_ia.cadastrar_produto('{"nome":"SSD 1TB","preco":459.90,"quantidade":6,"categoria":"Armazenamento","estoque_minimo":10}');

-- Histórico de movimentações (gera dados para "mais movimentados")
select estoque_ia.registrar_saida('{"nome":"Headset Gamer","quantidade":12,"observacao":"Venda balcão"}');
select estoque_ia.registrar_saida('{"nome":"Teclado Mecânico","quantidade":5,"observacao":"Venda online"}');
select estoque_ia.registrar_saida('{"nome":"Headset Gamer","quantidade":4,"observacao":"Venda online"}');
select estoque_ia.registrar_entrada('{"nome":"Monitor 24 polegadas","quantidade":2,"observacao":"Reposição parcial"}');
