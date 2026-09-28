# Magento Docker Environment (configurable Magento / PHP / search-engine versions)

A reusable template for spinning up Magento Open Source / Adobe Commerce on whichever
**Magento version**, **PHP version**, and **search engine** (OpenSearch or Elasticsearch) you
choose (defaults: Magento `2.4-develop` on PHP 8.4 with OpenSearch). Keep this folder as-is and
run one command per shop — each shop gets its own project folder, named after itself, as a
sibling of this template.

**Prerequisites:** Docker + the Docker Compose plugin, and
[mkcert](https://github.com/FiloSottile/mkcert) (for the locally-trusted HTTPS cert `./magento
init`/`./magento certs` generates — see [Service URLs & credentials](#service-urls--credentials)).

## Project layout

```
bin/            One file per subcommand (init, start, stop, cli, ...) — see "Day-to-day
                 commands" below. Each is a plain, independently readable script.
lib/
  common.sh     Shared helpers every bin/ script sources: die(), load_env(),
                set_env_var(), php_exec()/php_exec_t(), wait_for_db()/wait_for_search(),
                print_urls().
  versions.sh   Helpers for reading versions.tsv (versions_lookup, boundary-aware
                prefix matching).
  versions.tsv  The Magento <-> PHP / MariaDB / OpenSearch / Elasticsearch / Composer
                compatibility matrix — a single data file, not scattered case
                statements. Edit this to adjust what's offered/enforced.
docker/         Dockerfile + config for the custom php image, plus nginx/mariadb config.
env/            Per-service container env files (env_file: in docker-compose.yml) —
                opensearch.env, elasticsearch.env.
docker-compose.yml, .env(.example)   The stack definition and its configuration.
magento         Thin dispatcher: `./magento <cmd>` execs `bin/<cmd>`.
```

`./magento <cmd>` is still the single entry point you run day-to-day (see below) — the
`bin/`/`lib/` split is about keeping each command and each piece of shared logic in its own
file, not about changing how you invoke anything.

**Where Magento comes from depends on `MAGENTO_VERSION`:**
- Left at the default, `2.4-develop` — cloned from `magento/magento2` on **GitHub**
  (`MAGENTO_REPO_URL` in `.env`), tracking active development.
- Set to anything else, e.g. `2.4.8` — pulled as a tagged release from the **Adobe Commerce
  Marketplace** via `composer create-project`, same as a standard Magento install.

**Every dependency version is enforced against Adobe's official
[system requirements](https://experienceleague.adobe.com/en/docs/commerce-operations/installation-guide/system-requirements),**
read from [`lib/versions.tsv`](lib/versions.tsv) — the single data file both `bin/init` and this
table are sourced from. You choose Magento version, PHP version, and search engine; MariaDB and
the chosen search engine's own version are never prompted for, they're auto-selected to match:

| Magento version | PHP (you choose one) | MariaDB (auto) | OpenSearch      | Elasticsearch |
|------------------|-----------------------|----------------|-----------------|---------------|
| `2.4-develop`    | 8.3, 8.4, 8.5         | 11.8           | 3.8.0           | not supported |
| 2.4.9.x          | 8.5                   | 11.8           | 3.8.0           | not supported |
| 2.4.8.x          | 8.3, 8.4              | 11.4           | 3.8.0           | 8.11.0        |
| 2.4.7.x          | 8.2, 8.3              | 10.11          | 2.19.4          | 8.11.0        |
| 2.4.6.x          | 8.1, 8.2              | 10.11          | 2.19.4          | 7.17.5        |
| 2.4.5.x          | 8.1                   | 10.11          | not offered (†) | 7.17.5        |
| 2.4.4.x          | 8.1                   | 10.6           | not offered (†) | 7.17.5        |

"OpenSearch" / "Elasticsearch" columns are the version that gets started when you pick that
engine at `./magento init`; "not supported" means Adobe doesn't list that engine as supported for
that Magento version at all.

**(†)** 2.4.4/2.4.5 are a special case: Adobe's system-requirements page lists "OpenSearch 2.19"
for them too, but `setup:install`'s own `--search-engine=` option never gained a distinct
`opensearch` value until 2.4.6 (checked against every patch tag of
[`SearchConfigOptionsList.php`](https://github.com/magento/magento2/blob/2.4.6/setup/src/Magento/Setup/Model/SearchConfigOptionsList.php)
mirrored on GitHub for those two lines). What Adobe means is that OpenSearch 2.x speaks the same
wire protocol as the Elasticsearch 7.x client Magento uses there, so you *can* point that engine
at an OpenSearch host manually -- `bin/init` doesn't attempt that automatically, so it only offers
Elasticsearch (7.17.5, run against the `elasticsearch` service) for these two versions, which
installs correctly with no manual steps.

Both the PHP version and the search engine are chosen from a **numbered menu** built from exactly
what `lib/versions.tsv` lists as available for the Magento version you entered — there's no
free-text field for either, so an incompatible combination can't be typed in to begin with. On
2.4.4/2.4.5, for instance, the search-engine menu only ever shows one option, Elasticsearch,
auto-selected with no prompt:

```
  search engine: elasticsearch (only option compatible with your selection)
```

`MARIADB_VERSION`, `SEARCH_ENGINE`, `COMPOSE_PROFILES`, and the matching `OPENSEARCH_VERSION` /
`ELASTICSEARCH_VERSION` / `COMPOSER_VERSION` get written into `.env` automatically once you've
picked. `COMPOSE_PROFILES` is what makes `docker-compose.yml` start only the search engine you
picked — see the [Stack](#stack) table below.

All required PHP extensions (`bcmath`, `ctype`, `curl`, `dom`, `fileinfo`, `filter`, `ftp`,
`gd`, `hash`, `iconv`, `intl`, `json`, `libxml`, `mbstring`, `openssl`, `pcre`, `pdo_mysql`,
`reflection`, `simplexml`, `soap`, `sockets`, `sodium`, `spl`, `tokenizer`, `xmlwriter`, `xsl`,
`zip`, `zlib`) are present — most ship built into the base `php` image, the rest are built in
`docker/php/Dockerfile`.

## Stack

| Service       | Image                                                    | Purpose                            |
|---------------|-----------------------------------------------------------|-------------------------------------|
| php           | custom (`docker/php/Dockerfile`)                          | PHP-FPM (version chosen at init) with all Magento extensions |
| nginx         | nginx:stable-alpine                                        | Web server                          |
| db            | mariadb (version auto-selected, see the compatibility matrix above) | Database              |
| phpmyadmin    | phpmyadmin/phpmyadmin                                      | DB admin UI                         |
| opensearch    | opensearchproject/opensearch (version auto-selected)       | Catalog search engine (if chosen)   |
| elasticsearch | docker.elastic.co/elasticsearch/elasticsearch (auto-selected) | Catalog search engine (if chosen) |
| redis         | redis:7-alpine                                             | Cache backend + session storage     |
| mailpit       | axllent/mailpit                                            | Catches outgoing emails in dev      |

`opensearch` and `elasticsearch` both declare a Compose
[profile](https://docs.docker.com/compose/how-tos/profiles/) matching their own name
(`profiles: ["opensearch"]` / `["elasticsearch"]`). `./magento init` sets `COMPOSE_PROFILES` in
`.env` to whichever one you picked, so `docker compose up` (via `./magento start`) only ever
starts the search engine you're actually using — the other one's image is never even pulled.
Each engine's container-level settings (heap size, security plugin, etc.) live in its own file
under `env/` (`env/opensearch.env`, `env/elasticsearch.env`).

## Creating a new shop

From inside this template folder, run:

```bash
./magento init my_shop_name
```

This one command:

- **scaffolds a new project folder** at `../my_shop_name` (a sibling of this template folder),
  copying the docker setup into it — this template folder itself is never modified, so it stays
  clean and reusable for the next shop,
- creates `.env` from `.env.example` in that new folder,
- sets `COMPOSE_PROJECT_NAME` to `my_shop_name` there (so containers/volumes/hostnames don't
  clash with other shops on the same machine),
- **interactively asks which Magento version, PHP version, and search engine** to use (defaults
  come from `.env` — just press Enter to accept them). If you pick a PHP version or search engine
  Magento doesn't officially support for that release, the build **stops with an error** — it
  never continues on an unsupported combination. `MARIADB_VERSION`, `SEARCH_ENGINE`,
  `COMPOSE_PROFILES`, and the matching search-engine/Composer versions are then set automatically
  (see the compatibility matrix above),
- **asks which domain this shop should answer to** (default `localhost`) — sets `BASE_URL`, and if
  you give it a custom one (e.g. `store1.test`) adds it to `/etc/hosts` for you, prompting for
  `sudo` right there in the same terminal (see [Custom domains](#custom-domains-virtual-hosts)),
- builds the PHP image for the chosen version and starts MariaDB, Redis, your chosen search
  engine, Mailpit and phpMyAdmin,
- waits for the database and search engine to be ready,
- generates a locally-trusted HTTPS certificate for that domain via `./magento certs` (mkcert),
- asks for your **Adobe Commerce Marketplace public/private keys** the *first time only*
  (stored in `~/.composer-magento-docker` on your host, so every future shop reuses them — you
  never enter them again). Required either way: for a Marketplace install this authenticates
  the `composer create-project` pull itself; for the default `2.4-develop` GitHub clone it's
  still needed because some of its Composer dependencies are hosted on `repo.magento.com`,
- if `MAGENTO_VERSION` is left at the default `2.4-develop`, runs
  `git clone --branch 2.4-develop` against `MAGENTO_REPO_URL` (default: `magento/magento2` on
  GitHub) into `my_shop_name/public_html`, then `composer install`; otherwise runs
  `composer create-project` to pull that tagged release from the Adobe Commerce Marketplace,
- runs `bin/magento setup:install` wired up to MariaDB / your chosen search engine / Redis,
- sets developer mode, deploys static content, reindexes, flushes cache, and **disables static
  content signing** (`dev/static/sign`) — see [Known issue this avoids](#known-issue-this-avoids)
  below for why that matters,
- prints every service URL, and tells you to `cd` into `my_shop_name` to keep working on it.

Everything from here on (`start`, `stop`, `shell`, `cli`, …) is run from inside that new shop's
own folder — that's now a self-contained, independent project you can `git init` and push on its
own if you want.

If you re-run `./magento init` **from inside an existing shop folder** (i.e. the folder is
already named after the project), it skips scaffolding and re-installation and just (re)starts
the containers — safe to run again, e.g. after a reboot. If `public_html/` in that folder is
non-empty, the Composer/install steps are skipped either way.

## Day-to-day commands

Run these from inside a shop's own folder (not the template):

```bash
./magento certs             # (re)generate the local HTTPS cert -- auto-run by init/start already
./magento start             # start all containers, prints all service URLs
./magento stop              # stop all containers (data is kept)
./magento restart           # stop + start
./magento status            # docker compose ps
./magento shell             # bash inside the php container, dropped into /var/www/public_html
./magento cli <args>        # run bin/magento <args> inside the php container
./magento n98 <args>        # run n98-magerun2 (github.com/netz98/n98-magerun2) inside the php container
./magento import-db <file>  # import a .sql/.sql.gz dump into `db`, then setup:upgrade + reindex + cache:flush
./magento backend           # print the live admin URL (reads the running app's own config, not .env)
./magento xdebug [on|off]   # toggle Xdebug, or print its current mode with no argument
./magento logs [service]    # tail logs (all services, or one)
./magento destroy           # stop and DELETE containers + volumes (db/search data lost)
```

Examples:

```bash
./magento cli cache:flush
./magento cli indexer:reindex
./magento n98 db:console
./magento logs nginx
```

### Importing a database dump

A raw SQL import bypasses Magento's own tooling, so schema/data patches, the customer/order/product
grid tables, and the Redis cache all go stale relative to the freshly-swapped data — the usual symptom
is orders/customers/products sitting in the database but the admin grids showing nothing.
`./magento import-db` does the whole sequence for you:

```bash
./magento import-db ~/Downloads/shop-backup.sql       # or .sql.gz
```

That imports the dump into `db` (piped in from your host — no mysql/mariadb client needed inside a
container), then runs `setup:upgrade`, `indexer:reindex`, and `cache:flush`.

A dump also carries the source deployment's own settings for a few things that always need to
match *this* stack, not the original site, so `import-db` resets them automatically every time:

- `dev/static/sign` → `0` (production dumps rarely have this row at all, so it silently falls back
  to Magento's default of `1`; in developer mode that 404s `requirejs-config.js` specifically and
  breaks every admin page with a pile of "Script error for ..." console errors)
- `web/unsecure/base_url` / `web/secure/base_url` → this shop's `BASE_URL`, at the default scope
  *and* with any per-store-view override cleared (a store-scope value otherwise wins even after
  the default is fixed)
- `web/secure/use_in_frontend` / `web/secure/use_in_adminhtml` → `0` (this stack's HTTPS listener
  serves the same site as a convenience for manual testing — see [Service URLs &
  credentials](#service-urls--credentials) — but Magento's own base_url logic still isn't wired up
  for it, so these must stay off; a fresh local install never enables them either)
- `web/cookie/cookie_domain` → `""` (a dump's own domain here would make browsers silently drop
  the cookie on `localhost`, breaking login/session persistence)
- `catalog/search/engine` and its host/port/auth → this shop's local `opensearch`/`elasticsearch`
  service, per `SEARCH_ENGINE` in `.env`

If `setup:upgrade` itself fails (a real schema conflict — e.g. a custom module's table holding a
foreign key that blocks a core migration — rather than one of the three settings above), that needs
a case-by-case look, not something `import-db` can safely guess at.

A bare `mysql`/`mariadb` also works directly inside `./magento shell` (no `-h`/`-u`/`-p` needed — see
"Notes on PHP extensions" below for how that's wired up), for anything beyond a plain import.

Inside `./magento shell` you land directly in `/var/www/public_html` and can run Magento commands
straight away — no `cd`, no `php` prefix, not even `bin/` needed:

```bash
./magento shell
magento cache:flush
magento indexer:reindex
```

(`magento` here is just `bin/magento`, made runnable from anywhere via `PATH` in the image — it's
the same CLI, not a different tool.)

## Service URLs & credentials

Printed automatically by `./magento init` and `./magento start`. All of these are configurable
in a shop's `.env`.

- Storefront: `${BASE_URL}` → http://localhost/
- Admin: `${BASE_URL}admin` (`admin` / `Admin123!` by default)
- HTTPS: https://localhost/ (`NGINX_SSL_PORT` in `.env`, default `443`) — same site, served with a
  locally-trusted certificate from [mkcert](https://github.com/FiloSottile/mkcert), generated the
  first time by `./magento init`/`./magento start` (or manually via `./magento certs`). No browser
  "not secure" warning, since mkcert's CA is installed into your system/browser trust stores, not
  just self-signed. Magento's own config still defaults to `http://` (`web/secure/use_in_frontend`
  and `web/secure/use_in_adminhtml` stay `0`) — this listener is there if you want to test over
  HTTPS, not forced on you.
- phpMyAdmin: http://localhost:8080 (`magento` / `magento` by default)
- Search engine (OpenSearch or Elasticsearch, whichever you picked): http://localhost:9200
  (`SEARCH_PORT` in `.env`)
- Mailpit UI: http://localhost:8025 (SMTP on port 1025 — Magento's default mail transport is
  automatically caught here, nothing sent to the real internet)

## Custom domains (virtual hosts)

By default every shop answers to `localhost` (nginx has a single catch-all server block, so it
already accepts any hostname you throw at it — the pieces that actually need to agree on a domain
are Magento's own config and the HTTPS cert). To give a shop its own domain, e.g. `store1.test`:

- **On `./magento init`**, just answer the domain prompt (defaults to `localhost`) — it sets
  `BASE_URL` for you and adds the `/etc/hosts` entry it needs, prompting for `sudo` right there.
- **On an existing shop**, set `BASE_URL=http://store1.test/` in `.env`, then run `./magento cli
  config:set web/unsecure/base_url http://store1.test/ && ./magento cli config:set
  web/secure/base_url http://store1.test/ && ./magento cli cache:flush` (Magento reads base URLs
  from the database, not `.env`, once it's installed — see `bin/import-db` for the same pattern),
  and run `./magento restart` so the HTTPS cert regenerates for the new domain and `/etc/hosts`
  gets the new entry.
- **Either way**, every one of `init`/`start`/`restart`/`certs` checks `/etc/hosts` for the domain
  `BASE_URL` currently points at and, from an interactive terminal, appends it via `sudo tee` if
  it's missing — you'll just see one `sudo` password prompt (or none, if it's cached). It stops
  asking the moment the entry is there. If there's no terminal to prompt on (piped output, CI) or
  `sudo` isn't available, it falls back to printing the line for you to add by hand instead:
  ```
  127.0.0.1  store1.test
  ```

`./magento certs` (auto-run by `init`/`start`) reads `BASE_URL`'s domain and regenerates the
mkcert certificate to cover it alongside `localhost`/`127.0.0.1`/`::1`, so `https://store1.test/`
is trusted with no browser warning too.

A custom domain by itself doesn't let two shops run **at the same time** — every shop's nginx
still binds the same host ports unless you also change them (see [Running multiple shops at
once](#running-multiple-shops-at-once)). It does mean that once you do, each shop gets a
recognizable name (`https://store1.test:8443/`) instead of juggling which port is which shop.

## Known issues this avoids

**Admin stuck on the loading spinner, console full of `Script error for "..."` / 404s.**
Magento's static content signing (`dev/static/sign`, on by default) puts a `version.../` prefix
on admin and frontend asset URLs. In developer mode, a request for that versioned path 404s as a
literal file and gets routed through `static.php` for on-demand generation — which can't resolve
RequireJS's synthetic files (`requirejs-config.js` and everything it aliases: `jquery/ui`,
`prototype`, `jquery-ui-modules/*`, `text`, `mageTranslationDictionary`). That 404s
`requirejs-config.js` itself, so none of its path aliases ever register, cascading into a wall of
console errors and an admin panel stuck on the loading spinner forever.

`./magento init` disables `dev/static/sign` right after `setup:install` so this never happens.
If you ever hit this on a shop that predates the fix, run:

```bash
./magento cli config:set dev/static/sign 0
./magento cli cache:flush
```

then hard-refresh (Ctrl+Shift+R) the admin page.

**500 on the very first admin/storefront page load: `Class ...Proxy does not exist`.**
Developer mode is supposed to generate `Proxy`/`Factory`/`Interceptor` classes on demand the
first time each one is needed, but that on-the-fly generation is flaky under PHP-FPM's multiple
worker processes — two workers can race to generate the same class and one loses. `./magento
init` runs `bin/magento setup:di:compile` once right after install so every generated class
already exists before you ever load a page, which avoids the race entirely.

Trade-off: with everything pre-compiled, adding a *new* class that itself needs a generated
Proxy/Factory (e.g. a new `di.xml` virtual type or a constructor-injected dependency) won't
auto-generate anymore. If you hit that during development, just re-run:

```bash
./magento cli setup:di:compile
./magento cli cache:flush
```

## Xdebug

Xdebug is installed but disabled by default (`XDEBUG_MODE=off` in `.env`). Toggle it with:

```bash
./magento xdebug on    # sets XDEBUG_MODE=debug,develop in .env, restarts php
./magento xdebug off
./magento xdebug        # no argument -- just prints the current mode
```

(equivalent to hand-editing `XDEBUG_MODE` in `.env` and running `./magento restart`, if you'd
rather do that instead).

`xdebug.client_host` is set to `host.docker.internal`, mapped to the host gateway on Linux via
`extra_hosts` in `docker-compose.yml`, so it connects back to your IDE without extra config.

## Notes on PHP extensions

The `php` image includes everything Magento needs: `bcmath`, `gd`, `intl`, `pdo_mysql`,
`mysqli`, `soap`, `sockets`, `xsl`, `zip`, `exif`, `pcntl`, `ftp`, `opcache`, plus the `redis`
PECL extension. `imagick` is intentionally left out (Magento defaults to GD); add it to
`docker/php/Dockerfile` if a module you use requires it.

It also includes a `mysql`/`mariadb` CLI client and [n98-magerun2](https://github.com/netz98/n98-magerun2)
(`./magento n98 <args>`), a popular third-party Magento CLI covering things `bin/magento` doesn't
(`db:console`, `dev:console`, `sys:check`, `cache:report`, ...). The `php` service's `MYSQL_HOST`/`MYSQL_PWD`
env vars (`docker-compose.yml`) point that client at `db` by default, and its TLS default is turned off
client-side (`docker/php/Dockerfile`) since `db` has no TLS configured -- so a bare `mysql` or `mariadb`
inside `./magento shell` connects with no flags needed.

## Adjusting resources

- `PHP_MEMORY_LIMIT` and OPcache sizing live in `docker/php/php.ini`.
- MariaDB tuning (buffer pool, charset) lives in `docker/mariadb/my.cnf`.
- Search engine heap size and other container settings live in `env/opensearch.env` /
  `env/elasticsearch.env` (`OPENSEARCH_JAVA_OPTS` / `ES_JAVA_OPTS`).

## Running multiple shops at once

Each shop folder keeps its own `.env`, `./public_html` and Docker volumes, but they currently
share the same host ports (80, 443, 8080, 9200, etc.) and the same `.composer-magento-docker`
Marketplace credentials. To run two shops **at the same time**, change the port variables
(including `NGINX_SSL_PORT`) in one shop's `.env` before `init` (or edit them after and
`./magento restart`). If you only ever run one shop at a time (`./magento stop` on the current one
before `init`/`start` on the next), the default ports are fine as-is.

## What `init` does under the hood (manual equivalent)

The real logic lives in [`bin/init`](bin/init) — this is the same sequence spelled out by hand,
for when you need to run a step individually. From inside a shop's own folder:

```bash
docker compose up -d db redis opensearch mailpit phpmyadmin   # or "elasticsearch" instead of "opensearch"
./magento certs                                                # generates docker/nginx/certs/ via mkcert, if missing
docker compose up -d php nginx

docker compose exec --user www-data php composer global config http-basic.repo.magento.com <public-key> <private-key>

# Default (MAGENTO_VERSION=2.4-develop): clone from GitHub, then install dependencies
docker compose exec --user www-data php git clone --branch 2.4-develop --single-branch --depth 1 https://github.com/magento/magento2.git /var/www/public_html
docker compose exec --user www-data php composer install

# OR, for a specific release (e.g. MAGENTO_VERSION=2.4.8): pull from the Marketplace instead
docker compose exec --user www-data php composer create-project --repository-url=https://repo.magento.com/ magento/project-community-edition=2.4.8 /var/www/public_html

docker compose exec --user www-data php bin/magento setup:install \
  --base-url=http://localhost/ \
  --db-host=db --db-name=magento --db-user=magento --db-password=magento \
  --admin-firstname=Admin --admin-lastname=User --admin-email=admin@example.com \
  --admin-user=admin --admin-password=Admin123! \
  --language=en_US --currency=USD --timezone=UTC --use-rewrites=1 \
  --search-engine=opensearch --opensearch-host=opensearch --opensearch-port=9200 \
  --cache-backend=redis --cache-backend-redis-server=redis --cache-backend-redis-db=0 \
  --page-cache=redis --page-cache-redis-server=redis --page-cache-redis-db=1 \
  --session-save=redis --session-save-redis-host=redis --session-save-redis-db=2

# For Elasticsearch instead, swap the search-engine flags above for (the suffix is the ES
# major version -- "elasticsearch8" for 2.4.7/2.4.8, "elasticsearch7" for 2.4.4-2.4.6; see
# the compatibility table above):
#   --search-engine=elasticsearch8 --elasticsearch-host=elasticsearch --elasticsearch-port=9200

docker compose exec --user www-data php bin/magento deploy:mode:set developer
docker compose exec --user www-data php bin/magento config:set dev/static/sign 0
docker compose exec --user www-data php bin/magento setup:di:compile
docker compose exec --user www-data php bin/magento setup:static-content:deploy -f
docker compose exec --user www-data php bin/magento indexer:reindex
docker compose exec --user www-data php bin/magento cache:flush
```
