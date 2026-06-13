# Agente de Estoque com IA (n8n + PostgreSQL)

Atividade 4 — Recuperação de Frequência · Desenvolvimento de Software

Esse projeto é um agente que gerencia um estoque por conversa. Em vez de ter
telas e formulários, a pessoa escreve em português o que quer e o agente entende,
executa a operação no banco e responde. Por exemplo:

```
"Cadastra 50 unidades de Mouse Gamer por R$ 89,90"   ->  Produto cadastrado.
"Quantas unidades de teclado a gente tem?"            ->  Teclado Mecânico: 15 em estoque.
"O que tá com estoque baixo?"                         ->  Cadeira Gamer (3), SSD 1TB (6)...
```

A ideia foi montar tudo no n8n: ele recebe a mensagem, manda pro modelo de IA
decidir qual ação tomar, e o modelo chama as ferramentas que conversam com o
banco. A resposta volta pelo mesmo caminho, já em linguagem natural.

## Como funciona

O caminho de uma mensagem é mais ou menos esse:

```
usuário  ->  Chat Trigger (n8n)  ->  AI Agent + modelo de linguagem  ->  ferramentas Postgres  ->  banco
```

O AI Agent é o cérebro: ele lê o que a pessoa pediu, decide qual ferramenta usa
e monta os dados que precisa mandar. Cada ferramenta é ligada a uma função que
fica dentro do próprio banco (escrita em PL/pgSQL).

Resolvi deixar a lógica dentro do banco em vez de espalhar pelos nós do n8n por
três motivos. Primeiro, o fluxo no n8n fica limpo: cada nó só chama uma função e
pronto. Segundo, os parâmetros entram como `jsonb` por binding, então não tem
como montar SQL na mão e abrir brecha pra injeção. E terceiro, as regras de
negócio (checar se tem estoque suficiente antes de dar saída, calcular quanto
repor de cada item) ficam centralizadas num lugar só, em vez de espalhadas.

O detalhe do diagrama e do raciocínio por trás de cada decisão estão em
`docs/ARQUITETURA.md`, e o passo a passo visual em `docs/fluxograma.md`.

## Banco de dados

Tudo foi criado num schema separado chamado `estoque_ia`, pra não se misturar com
o resto do banco. São duas tabelas.

A `produtos` é o catálogo:

| coluna | tipo | pra que serve |
|--------|------|---------------|
| id | bigint (PK) | identificador |
| nome | text | nome do produto (único entre os ativos) |
| descricao / categoria | text | dados extras |
| preco | numeric(12,2) | preço unitário |
| quantidade | integer | quanto tem em estoque agora |
| estoque_minimo | integer | a partir de quando avisar pra repor |
| ativo | boolean | usado na exclusão lógica |
| criado_em / atualizado_em | timestamptz | controle de quando mudou |

A `movimentacoes` guarda o histórico de tudo que entra e sai:

| coluna | tipo | pra que serve |
|--------|------|---------------|
| id | bigint (PK) | identificador |
| produto_id | bigint (FK) | qual produto |
| tipo | text | `entrada` ou `saida` |
| quantidade | integer | quantas unidades |
| preco_unitario | numeric(12,2) | preço no momento da movimentação |
| observacao | text | de onde veio (venda, ajuste, etc.) |
| criado_em | timestamptz | quando aconteceu |

Uma decisão que vale comentar: a exclusão é lógica. Quando alguém "remove" um
produto, eu não apago a linha de verdade, só marco `ativo = false`. Assim o
histórico de movimentação não fica órfão e dá pra recuperar depois se precisar.

### As funções

Cada uma dessas funções é uma ferramenta que o agente pode usar:

| função | o que faz |
|--------|-----------|
| `cadastrar_produto` | cria um produto novo |
| `consultar_produto` | busca um produto pelo nome |
| `listar_produtos` | lista todos |
| `atualizar_produto` | muda dados ou a quantidade |
| `excluir_produto` | exclusão lógica |
| `registrar_entrada` | soma no estoque e registra a movimentação |
| `registrar_saida` | tira do estoque (checando se tem o suficiente) e registra |
| `consultar_estoque_baixo` | mostra o que tá abaixo do limite |
| `relatorio_produtos` | relatório com totais e valor do estoque |
| `produtos_mais_movimentados` | os que mais saíram |
| `alertas_reposicao` | o que precisa repor e quanto comprar de cada |

Todas funcionam igual: recebem um `jsonb` e devolvem um `jsonb` no formato
`{ sucesso, mensagem, dados }`. Padronizar assim facilitou do lado do modelo, que
só precisa montar um JSON e ler a resposta sempre do mesmo jeito.

## Como rodar

### 1. Banco

Roda os scripts da pasta `database/` nessa ordem (pelo SQL Editor do Supabase ou
pelo `psql`):

```
database/01_schema_e_tabelas.sql
database/02_funcoes_crud.sql
database/03_funcoes_movimentacao_relatorios.sql
database/04_seed_demonstracao.sql   (opcional, só dados de teste)
```

Como tudo cai no schema `estoque_ia`, não mexe em mais nada que já exista no banco.

### 2. n8n

1. Importa o fluxo: menu do n8n, *Import from File*, escolhe
   `n8n/workflow_agente_estoque.json`.
2. Cria uma credencial *Postgres* apontando pro mesmo banco (host, porta,
   database, usuário e senha) e seleciona ela nos nós de ferramenta.
3. No nó de Chat Model, coloca a API key do modelo. Deixei configurado o
   `gpt-4o-mini`, mas dá pra trocar por Anthropic, Gemini, Ollama (local) ou
   OpenRouter sem mudar mais nada — é só trocar o nó ligado na entrada Chat Model.
4. Abre o chat (botão *Open Chat* do Chat Trigger) e começa a conversar.

## Exemplos do que dá pra pedir

O agente entende as variações de linguagem natural, não precisa de comando fixo:

- "Cadastra 50 unidades de Mouse Gamer por R$ 89,90"
- "Quantas unidades de teclado a gente tem?"
- "Mostra tudo que tem no estoque"
- "Atualiza o Mouse Gamer pra 80 unidades"
- "Deu entrada de 20 teclados hoje"
- "Vendi 3 headsets"
- "Quais produtos estão com estoque baixo?"
- "Gera um relatório do estoque"
- "Quais os produtos mais vendidos?"
- "Tem algo precisando de reposição?"
- "Pode excluir a Cadeira Gamer"


