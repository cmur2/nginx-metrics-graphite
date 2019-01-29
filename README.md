# nginx-metrics-graphite

This is a Lua plugin for the Nginx web server that automatically collects and submits several important Nginx metrics to [Graphite](https://graphiteapp.org/) suitable for visualisation with e.g. [Grafana](http://grafana.org/).

In constrast to commercial and proprietary solutions such as  [Luameter](https://luameter.com/) or [NGINX Plus](https://www.nginx.com/products/) with it's [ngx_http_status_module](http://nginx.org/en/docs/http/ngx_http_status_module.html), this plugin is open source software while featuring more and additional metrics compared to those available via the open source  [ngx_http_stub_status_module](http://nginx.org/en/docs/http/ngx_http_stub_status_module.html). (Yea, [other web servers](https://redmine.lighttpd.net/projects/1/wiki/Docs_ModStatus) deliver more information by default...)

This plugin takes inspiration from other Nginx metric libraries like [nginx-lua-prometheus](https://github.com/knyar/nginx-lua-prometheus) but differs fundamentally in the metrics submission handling. In certain intervals it automatically pushes metrics to the configured instance(s) of [Carbon](https://github.com/graphite-project/carbon/) using pure Lua code instead of exposing them via a separate web page for HTTP polling. For that is uses the Graphite plaintext protocol over TCP establishing a new connection for every push.

The metrics collection happens on every request for which the user configures a suitable `log_by_lua` direcitve and towards server-wide global counters (finer granularity might be added later). The counters are realized using a single shared dictionary across all Nginx worker threads which has constant memory usage (128 KiB currently, may be reduced further).

Collected metrics in this prototype implementation:

* numbers of requests (total, to upstream, using ssl, using gzip)
* average request duration
* accumulated request sizes over all requests
* accumulated response sizes over all requests
* HTTP status code classes (1xx, 2xx, 3xx, 4xx, 5xx)
* HTTP methods (GET, HEAD, PUT, POST, DELETE, OPTIONS, others)
* HTTP versions (0.9, 1.0, 1.1, 2.0)

Successfully tested with:

* Nginx 1.6.2 and ngx_lua 0.9.12 on Debian Jessie
* Nginx 1.10.3 and ngx_lua 0.10.7 on Debian Stretch
* Nginx 1.14.0 and ngx_lua 0.10.13 from backports on Debian Stretch

## Caveats

A short metric submission interval might cause blocking on the Nginx workers since the shared dictionary storing all counters has to be locked.

Intermittent network errors while communicating with Graphite might leed to permanent loss of metric information. The communication happens in clear text and thus needs a secure separate network or other means.

If the Nginx worker elected (on Nginx startup) to run the submission loop is killed or dies no further metrics will be send until a restart.

## Install

* Install `nginx-extra` (includes Lua support) on Debian Jessie and Debian Stretch
* Clone the nginx-metrics-graphite repository to */opt/nginx-metrics-graphite*
* Add the following config to top-level `http` block (300 second submission interval):

    ```nginx
    resolver x.y.z.w; # DNS resolver IP address needed

    lua_shared_dict metrics_graphite 128k;
    lua_package_path ";;/opt/nginx-metrics-graphite/?.lua";
    init_by_lua 'metrics_graphite = require("metrics_graphite").init({"graphite.example.net"}, 300, "my.node.prefix")';
    init_worker_by_lua 'metrics_graphite:worker()';
    ```

* Instrument the `http` block or any server or location beneath it using `log_by_lua 'metrics_graphite:log()';`

## Development

```sh
apt-get install luarocks # on Debian

luarocks --local install luacheck
luacheck .
```

## License

nginx-metrics-graphite is licensed under the Apache License, Version 2.0. See LICENSE for more information.
