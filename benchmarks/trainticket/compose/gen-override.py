#!/usr/bin/env python3
"""Generate docker-compose.tt.yml, the one Compose override that makes TrainTicket 0.2.0
runnable on this host without touching its code or its compose file.

What it adds, per service, and why:
  - healthchecks: upstream ships none. Java services run Spring Boot 1.5 with actuator, so
    GET /health (200 = UP, 503 = DOWN; the Mongo indicator is inside it) is the readiness
    signal. Non-Java services get a TCP or HTTP check. Databases get their native pings.
  - state on ZFS: the 24 Mongo services have NO volumes upstream (state lives in the
    container layer and dies with it); MySQL has an anonymous one. Each gets a bind mount
    onto its own dataset, tank/tt-<name>, so it can be snapshotted and cloned.
  - pinned DB images: untagged `mongo`/`mysql` resolve to Mongo 8 / MySQL 9 today. The
    0.2.0 Mongo driver (3.4.3) speaks a wire protocol Mongo 5.1+ removed; pinned to 4.4.
    MySQL pinned to 5.7, which upstream's own k8s manifests use.
Usage: gen-override.py /path/to/upstream/docker-compose.yml > docker-compose.tt.yml
"""
import sys, yaml

src = yaml.safe_load(open(sys.argv[1]))["services"]
out = {}

# Readiness paths. Upstream's Spring Security config guards *every* path with its own
# JWT filter, actuator /health included (403), so the probe has to be a path each
# service's WebSecurityConfig permits. Every 0.2.0 controller exposes an unauthenticated
# GET /hello or /welcome under its API prefix; these were extracted from the v0.2.0
# source. Services without one (and the non-Java ones) fall back to a TCP check on
# their port, which proves the process is listening but not that it is wired up.
WELCOME = {
    "ts-admin-basic-info-service": "/api/v1/adminbasicservice/welcome",
    "ts-admin-order-service":      "/api/v1/adminorderservice/welcome",
    "ts-admin-route-service":      "/api/v1/adminrouteservice/welcome",
    "ts-admin-travel-service":     "/api/v1/admintravelservice/welcome",
    "ts-admin-user-service":       "/api/v1/adminuserservice/users/welcome",
    "ts-assurance-service":        "/api/v1/assuranceservice/welcome",
    "ts-auth-service":             "/api/v1/auth/hello",
    "ts-basic-service":            "/api/v1/basicservice/welcome",
    "ts-cancel-service":           "/api/v1/cancelservice/welcome",
    "ts-config-service":           "/api/v1/configservice/welcome",
    "ts-consign-price-service":    "/api/v1/consignpriceservice/welcome",
    "ts-consign-service":          "/api/v1/consignservice/welcome",
    "ts-food-service":             "/api/v1/foodservice/welcome",
    "ts-inside-payment-service":   "/api/v1/inside_pay_service/welcome",
    "ts-notification-service":     "/api/v1/notifyservice/welcome",
    "ts-order-other-service":      "/api/v1/orderOtherService/welcome",
    "ts-order-service":            "/api/v1/orderservice/welcome",
    "ts-payment-service":          "/api/v1/paymentservice/welcome",
    "ts-preserve-other-service":   "/api/v1/preserveotherservice/welcome",
    "ts-preserve-service":         "/api/v1/preserveservice/welcome",
    "ts-rebook-service":           "/api/v1/rebookservice/welcome",
    "ts-route-plan-service":       "/api/v1/routeplanservice/welcome",
    "ts-route-service":            "/api/v1/routeservice/welcome",
    "ts-seat-service":             "/api/v1/seatservice/welcome",
    "ts-security-service":         "/api/v1/securityservice/welcome",
    "ts-station-service":          "/api/v1/stationservice/welcome",
    "ts-ticketinfo-service":       "/api/v1/ticketinfoservice/welcome",
    "ts-travel-plan-service":      "/api/v1/travelplanservice/welcome",
    "ts-travel-service":           "/api/v1/travelservice/welcome",
    "ts-travel2-service":          "/api/v1/travel2service/welcome",
    "ts-user-service":             "/api/v1/userservice/users/hello",
}
# The UI is openresty; a 200 on / is its readiness. The news service is a Go binary
# whose image has wget but no bash, so /dev/tcp is not available there.
HTTP_ROOT = {"ts-ui-dashboard": "curl", "ts-news-service": "wget"}
# Java services with no unauthenticated GET at all (no welcome/hello in their controller).
JAVA_NO_WELCOME = {"ts-contacts-service", "ts-execute-service", "ts-food-map-service",
                   "ts-price-service", "ts-train-service", "ts-verification-code-service"}

# Java readiness accepts 200 or 403. Only 14 of the 37 services' SecurityConfig permit
# their own welcome path; the other 23 answer 403 from the JWT filter -- which is a
# fully initialised Spring context answering an HTTP request, i.e. exactly the
# "ready" signal a TCP check cannot give. A 404 is accepted only on the bare "/"
# fallback for the six services with no welcome path, where it is DispatcherServlet
# saying the context is up.
JAVA_PROBE = ("curl -s -o /dev/null -m 4 -w '%%{http_code}' http://127.0.0.1:%d%s "
              "| grep -qE '^(%s)$' || exit 1")

def hc(test, interval="10s", timeout="5s", retries=30, start="150s"):
    return {"test": test, "interval": interval, "timeout": timeout,
            "retries": retries, "start_period": start}

for name, svc in src.items():
    o = {}
    if name.endswith("-mongo"):
        o["image"] = "mongo:4.4"
        o["volumes"] = ["/tank/tt-%s:/data/db" % name[len("ts-"):]]
        o["healthcheck"] = hc(["CMD-SHELL", "mongo --quiet --eval 'db.runCommand({ping:1}).ok' | grep -q 1"],
                              interval="5s", retries=20, start="20s")
    elif name.endswith("-mysql"):
        o["image"] = "mysql:5.7"
        o["volumes"] = ["/tank/tt-%s:/var/lib/mysql" % name[len("ts-"):]]
        o["healthcheck"] = hc(["CMD-SHELL", "mysqladmin ping -uroot -proot --silent"],
                              interval="5s", retries=30, start="30s")
    elif name == "redis":
        o["healthcheck"] = hc(["CMD-SHELL", "redis-cli ping | grep -q PONG"], interval="5s", retries=10, start="5s")
    elif "ports" in svc:
        port = int(str(svc["ports"][0]).split(":")[1])
        if name in WELCOME:
            test = ["CMD-SHELL", JAVA_PROBE % (port, WELCOME[name], "200|403")]
        elif name in JAVA_NO_WELCOME:
            test = ["CMD-SHELL", JAVA_PROBE % (port, "/", "200|403|404")]
        elif name in HTTP_ROOT:
            tool = "curl -fsS -o /dev/null" if HTTP_ROOT[name] == "curl" else "wget -qO /dev/null"
            test = ["CMD-SHELL", "%s http://127.0.0.1:%d/ || exit 1" % (tool, port)]
        else:
            # bash's /dev/tcp: present in every image here, including the Go one (./app)
            # which ships no HTTP client at all.
            test = ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/%d' || exit 1" % port]
        o["healthcheck"] = hc(test)
    else:
        continue
    out[name] = o

print("# Generated by gen-override.py from TrainTicket's docker-compose.yml. Do not edit.")
print("# See the docstring in gen-override.py for what each addition is for.")
yaml.safe_dump({"services": out}, sys.stdout, sort_keys=False, default_flow_style=False)
