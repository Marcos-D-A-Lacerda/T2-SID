# T2 — Tolerância a falhas com replicação PostgreSQL e balanceamento Nginx

Projeto da disciplina de Sistemas Distribuídos. O objetivo é acrescentar tolerância a falhas à API HTTP de produtos desenvolvida no T1, avaliar o comportamento diante de falhas e registrar métricas de desempenho.

## 1. Arquitetura

```text
                   Cliente / JMeter
                         |
                         v
                   Nginx :8080
                    /        \
                   v          v
            API Express    API Express
              :3001          :3002
                   \          /
                    v        v
              PostgreSQL primário
                localhost:5433
                         |
                         | Replicação física WAL (assíncrona)
                         v
              PostgreSQL standby
                localhost:5434
```

- **Duas instâncias da API:** processos Node.js/Express distintos no Windows, com o mesmo código e conexão ao banco primário.
- **Nginx:** executado em container Docker e distribuindo requisições entre as APIs.
- **PostgreSQL:** primário e standby executados em containers Docker, usando replicação física por streaming WAL.
- **Failover do banco:** **manual**; a promoção do standby foi testada, mas a API ainda **não** realiza reconexão automática ao novo primário.
- **Escopo:** os experimentos em uma única máquina avaliam falha de processos/containers, **não** falha física do host.

## 2. Requisitos

- Windows 10/11 com WSL 2 disponível e virtualização habilitada.
- [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) com engine Linux e `docker compose`.
- [Node.js](https://nodejs.org/) 18 ou superior e npm (ou a versão exigida pelo T1).
- [Git](https://git-scm.com/downloads).
- Editor de código, como VS Code (recomendado).
- [Apache JMeter](https://jmeter.apache.org/) para os experimentos de carga (etapa seguinte; não é necessário para iniciar a arquitetura).

Verifique o ambiente no PowerShell:

```powershell
docker --version
docker compose version
docker info
node --version
npm --version
git --version
```

> O Docker Desktop precisa estar **aberto e com o engine iniciado**. Se o comando `docker info` não apresentar a seção `Server`, abra o Docker Desktop antes de continuar.

## 3. Estrutura do repositório

```text
T2-tolerancia/
├── README.md
├── .gitignore
├── docker-compose.yml
├── primary-init/
│   ├── 01-replication.sql
│   └── 02-pg-hba.sh
├── nginx/
│   └── default.conf
└── api/
    ├── package.json
    ├── package-lock.json
    ├── .env.example
    ├── sql/
    └── ...demais arquivos da API do T1
```

> Os arquivos `docker-compose.yml`, `primary-init/`, `nginx/` e o **código real da API** precisam ser versionados; o README não substitui esses arquivos. Não inclua `node_modules`, `.env`, dados de volumes ou credenciais reais.

## 4. Iniciar os bancos e o Nginx

Na raiz do repositório:

```powershell
docker compose config
docker compose up -d
docker compose ps
```

Portas do laboratório:

| Serviço | Endereço |
|---|---|
| Nginx | `http://localhost:8080` |
| API 1 | `http://localhost:3001` |
| API 2 | `http://localhost:3002` |
| PostgreSQL primário | `127.0.0.1:5433` |
| PostgreSQL standby | `127.0.0.1:5434` |

**Atenção:** o Nginx precisará das duas APIs rodando no Windows para encaminhar as requisições. Um erro `502 Bad Gateway` antes de iniciar as APIs é esperado.

## 5. Configurar e iniciar a API

Na pasta `api/`, crie um arquivo `.env` com base em `.env.example` e configure a conexão **local**. Exemplo usando as credenciais **exclusivas de demonstração** do laboratório original:

```dotenv
DATABASE_URL=postgresql://postgres:postgres_demo_2026@127.0.0.1:5433/produtos
DB_SSL=false
PORT=3001
```

O projeto utiliza `pg.Pool` e precisa permitir desligar o SSL apenas no laboratório local. Exemplo de configuração:

```javascript
const { Pool } = require('pg');
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: true },
  max: 20,
});
module.exports = { pool };
```

Garanta que o arquivo principal carregue o `.env` e utilize `process.env.PORT` para definir a porta. Para criar as tabelas e dados, execute o seed **somente depois de confirmar que `DATABASE_URL` aponta para `127.0.0.1:5433`**. O seed do T1 pode truncar a tabela de produtos.

```powershell
cd .\api
npm install
node -e "require('dotenv').config(); const u = new URL(process.env.DATABASE_URL); console.log(u.hostname, u.port, u.pathname)"
npm run seed
```

O comando de verificação deve mostrar `127.0.0.1 5433 /produtos`.

Em **dois terminais diferentes**, ambos dentro da pasta `api/`:

**Terminal 1:**

```powershell
$env:PORT = '3001'
npm start
```

**Terminal 2:**

```powershell
$env:PORT = '3002'
npm start
```

Teste as rotas existentes no projeto (a rota de saúde é **`/health`**, não `/status`):

```powershell
Invoke-RestMethod http://localhost:3001/health
Invoke-RestMethod http://localhost:3002/health
Invoke-RestMethod http://localhost:8080/health
Invoke-RestMethod http://localhost:8080/produtos
```

O balanceador usa `host.docker.internal` para acessar as instâncias Node.js executadas no Windows.

## 6. Validar a replicação PostgreSQL

Verifique a conexão de replicação no primário:

```powershell
docker exec t2-primary psql -U postgres -d produtos -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
```

O esperado é `state = streaming` e `sync_state = async`.

Confirme os papéis:

```powershell
docker exec t2-primary psql -U postgres -d produtos -c "SELECT pg_is_in_recovery();"
docker exec t2-standby psql -U postgres -d produtos -c "SELECT pg_is_in_recovery();"
```

Resultado esperado: `false` no primário e `true` no standby.

Para testar a reprodução dos dados:

```powershell
docker exec t2-primary psql -U postgres -d produtos -c "CREATE TABLE IF NOT EXISTS teste_replicacao (id SERIAL PRIMARY KEY, mensagem TEXT NOT NULL);"
docker exec t2-primary psql -U postgres -d produtos -c "INSERT INTO teste_replicacao (mensagem) VALUES ('registro replicado');"
docker exec t2-standby psql -U postgres -d produtos -c "SELECT * FROM teste_replicacao;"
```

O secundário deve mostrar o registro inserido no primário. Como a replicação é assíncrona, pode haver pequeno atraso.

## 7. Teste de failover manual do banco

**Faça este teste somente em um ambiente descartável de laboratório** e registre evidências antes. Ao promovê-lo, o secundário passa a aceitar escrita, mas isso não redireciona automaticamente a API.

```powershell
docker stop t2-primary
docker exec t2-standby psql -U postgres -d produtos -c "SELECT pg_is_in_recovery();"
docker exec t2-standby psql -U postgres -d produtos -c "SELECT pg_promote(true, 60);"
docker exec t2-standby psql -U postgres -d produtos -c "SELECT pg_is_in_recovery();"
docker exec t2-standby psql -U postgres -d produtos -c "INSERT INTO teste_replicacao (mensagem) VALUES ('escrita apos failover');"
docker exec t2-standby psql -U postgres -d produtos -c "SELECT * FROM teste_replicacao;"
```

Resultado esperado: após a promoção, `pg_is_in_recovery()` retorna `false` no antigo standby e a inserção funciona.

**Não religue o antigo primário sem reintegrá-lo corretamente**, pois isso pode criar dois primários divergentes (*split-brain*).

Para reiniciar o laboratório do zero **apagando todos os dados dos volumes locais desse Compose**:

```powershell
docker compose down -v
docker compose up -d
```

Esse procedimento de descarte **não** deve ser usado com dados que precisem ser preservados.

## 8. Teste da falha de uma API pelo Nginx

Com as duas APIs ativas, interrompa apenas a instância da porta `3001` (`Ctrl+C` no terminal dela). Mantenha a API 2 e o Nginx ativos.

```powershell
1..10 | ForEach-Object {
    try {
        $r = Invoke-WebRequest -UseBasicParsing http://localhost:8080/health
        "Teste ${_}: HTTP $($r.StatusCode) | Backend $($r.Headers['X-Upstream'])"
    } catch {
        "Teste ${_}: FALHA - $($_.Exception.Message)"
    }
}
```

No experimento já realizado, as **10 requisições obtiveram HTTP 200**. Algumas exibiram no cabeçalho `X-Upstream` uma tentativa no backend `3001` seguida de sucesso no `3002`. Trata-se de **evidência de failover HTTP**; não é prova de ausência de erros sob cargas maiores.

## 9. Próximos experimentos (ainda pendentes)

- Comparar o desempenho no JMeter com as duas APIs ativas versus a interrupção da API 1 durante a carga (100 usuários virtuais, ramp-up de 10 s, duração de 60 s, requisições `GET /produtos` via `localhost:8080`).
- Registrar `samples`, throughput, taxa de erros, média, P90, P95 e P99 e o instante da falha.
- Avaliar a recuperação da aplicação após a promoção do banco secundário; a troca de conexão **não está automatizada** nesta versão.
- Discutir os trade-offs da replicação física assíncrona, incluindo a possibilidade de perda de transações recentemente confirmadas em falhas do primário.

## 10. Problemas comuns

| Sintoma | Verificação |
|---|---|
| `docker compose up -d` falha ao acessar `dockerDesktopLinuxEngine` | Abra o Docker Desktop e aguarde o engine Linux iniciar; confira `docker info`. |
| `Cannot GET /status` | A rota correta da API deste projeto é `/health`. |
| Erro de SSL da API com o banco local | Verifique `DB_SSL=false`, a configuração do `pg.Pool` e a ausência de `sslmode=require` na URL local. |
| Nginx retorna `502` | Verifique se as APIs estão executando nas portas `3001` e `3002`. |
| Dados não aparecem no standby | Consulte `pg_stat_replication` e os logs: `docker compose logs --tail=50`. |
| `npm run seed` não conecta | Verifique que o PostgreSQL primário está ativo na porta `5433` e que `DATABASE_URL` aponta para o banco local. |

## 11. Segurança e versionamento

- Não publique `.env`, tokens, senhas de serviço, credenciais do Neon, `node_modules` ou dados persistidos dos bancos.
- As credenciais de demonstração usadas no exemplo **não devem** ser reutilizadas em ambientes reais; prefira variáveis de ambiente em qualquer repositório público.
- Confira os arquivos com `git status` e `git diff --cached --name-only` antes de cada `git push`.
- Caso credenciais reais já tenham sido publicadas, removê-las de commits novos não basta: revogue/rotacione essas credenciais.

## Referências

- [Docker Desktop no Windows](https://docs.docker.com/desktop/setup/install/windows-install/)
- [PostgreSQL — Warm Standby e Streaming Replication](https://www.postgresql.org/docs/16/warm-standby.html)
- [PostgreSQL — Replication](https://www.postgresql.org/docs/16/runtime-config-replication.html)
- [Nginx — HTTP Load Balancing](https://docs.nginx.com/nginx/admin-guide/load-balancer/http-load-balancer/)
- [Apache JMeter](https://jmeter.apache.org/)
