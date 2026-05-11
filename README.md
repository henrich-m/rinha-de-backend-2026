# Rinha de Backend 2026 🏁

**Programar é divertido! Vamo lá!**

Uma implementação de API para detecção de fraude usando busca por vetores em um conjunto de dados de 3 milhões de transações. Este projeto participa da **Rinha de Backend 2026**, uma competição de backend focada em performance e precisão.

---

## 🎯 Objetivo do Desafio

Para cada requisição `POST /fraud-score`, você deve:

1. **Transformar** o payload de transação em um vetor normalizado de 14 dimensões
2. **Buscar** os 5 vizinhos mais próximos no dataset de referência (~3M vetores)
3. **Calcular** um score de fraude baseado na proximidade com transações fraudulentas
4. **Retornar** uma decisão de aprovação e o score em tempo real

**Restrições críticas:**
- Budget total: **1 CPU + 350 MB RAM** para todos os serviços
- Mínimo: **1 load balancer + 2 instâncias de API** (round-robin)
- Porta: **9999** (exposta no load balancer)
- Latência P99: ≤ 10ms (para score máximo)
- Taxa de erro: < 15%

---

## 🏗️ Stack Tecnológico

| Componente | Tecnologia |
|-----------|-----------|
| **Linguagem** | Ruby 4 |
| **Servidor** | Falcon (async fiber) |
| **Router** | Roda |
| **JSON** | Oj |
| **Banco de Dados** | PostgreSQL 16 + pgvector |
| **Pool de Conexões** | PgBouncer |
| **Load Balancer** | nginx |
| **Containerização** | Docker + Docker Compose |

**Linguagens do repositório:**
- Ruby: 93.2%
- Makefile: 4.6%
- Dockerfile: 2.2%

---

## 🚀 Quick Start

### Primeiro acesso (instalar dependências)

```bash
# Instalar gems e capturar Gemfile.lock
docker compose -f docker-compose.dev.yml run --rm api bundle install
docker compose -f docker-compose.dev.yml run --rm api cat Gemfile.lock > Gemfile.lock
```

### Iniciar o servidor

```bash
# Subir todos os serviços em background
docker compose -f docker-compose.dev.yml up -d

# Ver logs em tempo real
docker compose -f docker-compose.dev.yml logs -f api

# Testar a API
curl http://localhost:9999/ready
```

### Executar testes

```bash
# Teste suite de um milestone (servidor deve estar rodando)
docker compose -f docker-compose.dev.yml exec api bundle exec ruby -Itest test/m01_skeleton_test.rb

# Rodar todos os testes
docker compose -f docker-compose.dev.yml exec api bundle exec rake test
```

### Parar o servidor

```bash
docker compose -f docker-compose.dev.yml down
```

---

## 📡 Contrato da API

### Porta
Todos os endpoints escutam na **porta 9999**

### Endpoints

#### `GET /ready`
Verifica se a API está pronta para receber tráfego.

**Resposta:** HTTP 2xx quando pronta

```bash
curl http://localhost:9999/ready
```

#### `POST /fraud-score`
Analisa uma transação e retorna o score de fraude.

**Request:**
```json
{
  "id": "tx_12345",
  "transaction": {
    "amount": 150.50,
    "installments": 3,
    "requested_at": "2026-05-11T10:30:45Z"
  },
  "customer": {
    "avg_amount": 100.00,
    "tx_count_24h": 5,
    "known_merchants": ["merc_001", "merc_002"]
  },
  "merchant": {
    "id": "merc_003",
    "mcc": "5411",
    "avg_amount": 120.00
  },
  "terminal": {
    "is_online": true,
    "card_present": false
  },
  "location": {
    "km_from_last_tx": 50.0,
    "km_from_home": 10.0
  },
  "last_transaction": {
    "minutes_ago": 120
  }
}
```

**Response:**
```json
{
  "approved": true,
  "fraud_score": 0.15
}
```

---

## 🧮 Vetorização – 14 Dimensões

Cada transação é transformada em um vetor de 14 floats normalizados para o intervalo [0.0, 1.0]. As constantes vêm de `resources/normalization.json`.

**Função de normalização:** `clamp(x) = min(max(x, 0.0), 1.0)`

| Índice | Dimensão | Fórmula |
|--------|----------|---------|
| 0 | amount | `clamp(amount / 10000)` |
| 1 | installments | `clamp(installments / 12)` |
| 2 | amount_vs_avg | `clamp((amount / customer.avg_amount) / 10)` |
| 3 | hour_of_day | `hour(requested_at, UTC) / 23` |
| 4 | day_of_week | `weekday(requested_at) / 6` (seg=0, dom=6) |
| 5 | minutes_since_last_tx | `clamp(minutes / 1440)` ou **`-1`** se sem transação anterior |
| 6 | km_from_last_tx | `clamp(km / 1000)` ou **`-1`** se sem transação anterior |
| 7 | km_from_home | `clamp(km_from_home / 1000)` |
| 8 | tx_count_24h | `clamp(tx_count_24h / 20)` |
| 9 | is_online | `1` se online, `0` caso contrário |
| 10 | card_present | `1` se cartão presente, `0` caso contrário |
| 11 | unknown_merchant | `1` se merchant.id NÃO está em known_merchants, `0` caso contrário |
| 12 | mcc_risk | `mcc_risk.json[merchant.mcc]` (padrão: `0.5`) |
| 13 | merchant_avg_amount | `clamp(merchant.avg_amount / 10000)` |

**⚠️ Importante:**
- A sentinela `-1` nos índices 5 e 6 é **intencional** e NÃO deve ser clamped
- Ela sinaliza "sem transação anterior" e agrupa naturalmente vetores similares no espaço
- Fórmula de weekday: `(Time#wday + 6) % 7` converte ruby (dom=0) para spec (seg=0, dom=6)

---

## 📚 Dataset de Referência

O projeto inclui três arquivos de dados críticos (em `resources/`):

### `references.json.gz`
- **Tamanho:** 3 milhões de vetores pré-calculados
- **Formato:** `[{ "vector": [...14 floats...], "label": "fraud"|"legit" }, ...]`
- **Ação:** Descompactar no startup e indexar para busca rápida

### `mcc_risk.json`
- Mapping de MCC (código de categoria de merchant) para score de risco [0.0-1.0]
- Usado para calcular dimensão 12 do vetor

### `normalization.json`
- Constantes de normalização (max_amount, max_installments, etc.)
- Define os divisores para cada dimensão

**Pré-processamento:** Estes arquivos **nunca mudam durante o teste**. Descompacte, processe e indexe-os no build ou startup do container.

---

## ⚡ Otimização de Performance

O brute-force KNN sobre 3M × 14 dimensões é O(N·D) — muito lento sob carga.

### Estratégias Recomendadas

1. **HNSW** (Hierarchical Navigable Small World)
   - Suportado nativamente por pgvector
   - Sub-linear, ótimo para alta dimensionalidade

2. **IVF** (Inverted File Index)
   - Bom para datasets muito grandes
   - Requer trade-off entre velocidade e precisão

3. **VP-Tree** (Vantage Point Tree)
   - Implementável em Ruby puro
   - Bom para k pequeno

### Ganhos Principais

- **Mover pré-processamento para fora do hot path** (decompress, build index) é o maior ganho
- Buscar o índice em memória ou cache é 100x mais rápido que recalcular
- Target: **P99 ≤ 10ms** para score máximo; abaixo de 1ms satura em +3000

---

## 🐳 Configuração Docker

### Desenvolvimento: `docker-compose.dev.yml`

- Source code **volume-mounted** em `/app`
- Gems persistem em `bundle_cache` volume em `/usr/local/bundle`
- Rebuild apenas quando `Gemfile` muda
- Porta 9999 exposta localmente

### Produção: `Dockerfile`

- Produção image; source é **COPYed in** (não mounted)
- Otimizado para tamanho e segurança
- Variáveis de ambiente para configuração

### Entry Point

- `config.ru` na raiz do repositório
- Falcon carrega automaticamente via `falcon serve`
- Requer `src/server.rb` e chama `run App` (subclass Roda)

---

## 🔄 Fluxo de Submissão

Seu repositório precisa de **duas branches:**

### `main`
- Código-fonte completo
- Todas as dependências
- Documentação

### `submission`
- Apenas `docker-compose.yml` e configs necessários
- **Sem código-fonte**
- Pronto para build e deploy

### Teste

1. Abra uma **GitHub Issue**
2. Inclua `rinha/test` no corpo da issue
3. O Rinha Engine executa os testes
4. Resultados são postados na issue
5. Issue é fechada automaticamente

---

## 🎯 Sistema de Scoring

```
final_score = score_p99 + score_det
```

Cada componente varia de −3000 a +3000.

### score_p99 (Latência)
```
score_p99 = 1000 · log₁₀(1000 / max(p99_ms, 1))
```
- Floor em −3000 se P99 > 2000ms
- +3000 se P99 < 1ms

### score_det (Detecção)
```
score_det = 1000 · log₁₀(1/ε) − 300 · log₁₀(1 + E)
```

Onde:
- `ε` = taxa de erro
- `E = 1·FP + 3·FN + 5·Err` (erro HTTP custa 5x mais)
- Floor em −3000 se taxa de falha > 15%

**Implicação crítica:** Erros HTTP (5xx) custam 5× mais que falsos positivos. Se sua API não pode decidir, retorne `approved: true, fraud_score: 0.0` em vez de 5xx.

---

## 📋 Checklist de Implementação

- [ ] Setup de ambiente Docker com Ruby 4 + Falcon
- [ ] Implementar endpoints `/ready` e `/fraud-score`
- [ ] Carregar e descompactar dataset (3M vetores)
- [ ] Implementar função de vetorização (14 dimensões)
- [ ] Implementar busca de K-vizinhos mais próximos
- [ ] Implementar algoritmo de decisão (fraud vs legit)
- [ ] Configurar nginx como load balancer
- [ ] Setup de 2+ instâncias de API
- [ ] Otimizar latência (target P99 ≤ 10ms)
- [ ] Testar com Rinha Engine
- [ ] Criar branch `submission` com compose.yml
- [ ] Submeter via GitHub Issue

---

## 🛠️ Notas de Desenvolvimento

### Quirk Conhecido

`protocol-rack` chama `peer.ip_address`, mas `Async::IO::Socket` (de `async-io`) apenas expõe `remote_address`. O patch em `config.ru` adiciona este método via `prepend`. Não remova este patch!

### Vectorizer

```ruby
vectorizer = Vectorizer.new(normalization_path, mcc_risk_path)
vector = vectorizer.vectorize(payload)  # Retorna array de 14 floats
```

- Caminhos são passados explicitamente (sem `__dir__` tricks)
- Sentinela `-1` nos índices 5 e 6 nunca é clamped
- Fórmula de weekday: `(Time#wday + 6) % 7`

### Estrutura do Repositório

```
.
├── config.ru                 # Entry point Roda/Falcon
├── src/
│   ├── server.rb            # Aplicação Roda
│   ├── vectorizer.rb        # Lógica de vetorização
│   └── ...
├── test/
│   ├── m01_skeleton_test.rb
│   ├── m02_*.rb
│   └── ...
├── resources/
│   ├── references.json.gz   # 3M vetores (comprimido)
│   ├── mcc_risk.json
│   └── normalization.json
├── docker-compose.dev.yml   # Desenvolvimento
├── docker-compose.yml       # Produção
├── Dockerfile               # Build produção
├── Gemfile
├── Gemfile.lock
├── Makefile
└── README.md
```

---

## 📚 Referências

- [Rinha de Backend](https://github.com/zanfranceschi/rinha-de-backend)
- [pgvector](https://github.com/pgvector/pgvector)
- [Falcon Web Server](https://github.com/socketry/falcon)
- [Roda](https://github.com/jeremyevans/roda)
- [HNSW](https://arxiv.org/abs/1603.09320)

---

## 📝 Licença

MIT © 2026 henrich-m

---

**Boa sorte! 🚀**
