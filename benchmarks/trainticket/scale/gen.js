// TrainTicket 0.2.0 scale generator. Runs in the legacy `mongo` shell (4.4) inside a
// throwaway container on the Compose network, reads reference data from the Mongos that
// own it and bulk-inserts into the Mongos that own the generated collections, so every
// cross-service reference is real:
//   order.accountId -> auth.user.userId == user.user.userId == contacts.accountId
//   order.trainNumber -> travel|travel2.trip._id{type,number}
//   trip.routeId -> route.routes._id ; trip.trainTypeId -> train.trainType._id
//   (trip.trainTypeId, trip.routeId) -> price.price_config ; order.price derived from it
//   payment.orderId -> order._id ; payment.userId -> order.accountId
// Documents copy the seeded ones byte for byte in shape: Spring Data's `_class`, Java
// legacy UUIDs (BinData subtype 3 via JUUID), string UUIDs where the app uses strings.
// Params come from --eval: N_USERS, N_TRIPS, N_ORDERS, SEED, BATCH.

var N_USERS = typeof N_USERS !== 'undefined' ? N_USERS : 10000;
var N_TRIPS = typeof N_TRIPS !== 'undefined' ? N_TRIPS : 1000;
var N_ORDERS = typeof N_ORDERS !== 'undefined' ? N_ORDERS : 1000000;
var SEED = typeof SEED !== 'undefined' ? SEED : 42;
var BATCH = typeof BATCH !== 'undefined' ? BATCH : 10000;

// mulberry32: deterministic, good enough. The seed is mixed with what already exists so
// an additive second run never replays the first run's UUID sequence (which is a
// duplicate-key error on the first batch, and `ordered:false` then leaves a partial batch).
var _s = SEED >>> 0;
function reseed(u0, t0) { _s = (SEED ^ Math.imul(u0 + 1, 2654435761) ^ Math.imul(t0 + 1, 40503)) >>> 0; }
function rnd() { _s = (_s + 0x6D2B79F5) >>> 0; var t = _s; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }
function ri(n) { return Math.floor(rnd() * n); }
function pick(a) { return a[ri(a.length)]; }
function hex(n) { var s = ''; for (var i = 0; i < n; i++) s += '0123456789abcdef'[ri(16)]; return s; }
function uuidStr() { var h = hex(32); return h.substr(0,8)+'-'+h.substr(8,4)+'-4'+h.substr(13,3)+'-'+'89ab'[ri(4)]+h.substr(17,3)+'-'+h.substr(20,12); }
// Java legacy UUID (BinData subtype 3), what mongo-java-driver 3.4 / Spring Data 1.10 wrote:
// each 64-bit half of the UUID stored little-endian, i.e. both 8-byte halves byte-reversed.
// Verified against the seeded fdse_microservice: 4d2a46c7-71cb-4cf1-b5bb-b68406d9da6f is
// stored as f14ccb71c7462a4d 6fdad90684b6bbb5. The 4.4 shell has no JUUID() helper.
function rev8(x) { var o = ''; for (var i = 14; i >= 0; i -= 2) o += x.substr(i, 2); return o; }
function juuid(s) { var h = s.replace(/-/g, ''); return HexData(3, rev8(h.substr(0, 16)) + rev8(h.substr(16, 16))); }
function juuidToStr(b) { var h = b.hex(); var x = rev8(h.substr(0, 16)) + rev8(h.substr(16, 16)); return x.substr(0,8)+'-'+x.substr(8,4)+'-'+x.substr(12,4)+'-'+x.substr(16,4)+'-'+x.substr(20); }
function pad(n, w) { var s = '' + n; while (s.length < w) s = '0' + s; return s; }
function tsec() { return new Date().getTime(); }
function report(label, n, ms) { print('  ' + label + ': ' + n + ' docs in ' + (ms/1000).toFixed(1) + ' s = ' + Math.round(n / Math.max(ms,1) * 1000) + ' docs/s'); }
function flush(coll, buf, cls) { if (!buf.length) return 0; coll.insertMany(buf, {ordered: false}); var n = buf.length; buf.length = 0; return n; }

var dbAuth = connect('ts-auth-mongo:27017/ts-auth-mongo');
var dbUser = connect('ts-user-mongo:27017/ts-user-mongo');
var dbContacts = connect('ts-contacts-mongo:27017/ts');
var dbRoute = connect('ts-route-mongo:27017/ts');
var dbTrain = connect('ts-train-mongo:27017/ts');
var dbPrice = connect('ts-price-mongo:27017/ts');
var dbTravel = connect('ts-travel-mongo:27017/ts');
var dbTravel2 = connect('ts-travel2-mongo:27017/ts');
var dbOrder = connect('ts-order-mongo:27017/ts');
var dbOrderOther = connect('ts-order-other-mongo:27017/ts');
var dbPayment = connect('ts-payment-mongo:27017/ts');
var dbInside = connect('ts-inside-payment-mongo:27017/ts');

// ---------------------------------------------------------------- reference data
var routes = {}; dbRoute.routes.find().forEach(function (r) { routes[r._id] = r; });
var trainTypes = {}; dbTrain.trainType.find().forEach(function (t) { trainTypes[t._id] = t; });
var priceCfg = dbPrice.price_config.find().toArray();          // (trainType, routeId) pairs
var seedAuth = dbAuth.user.findOne({username: 'fdse_microservice'});
var bcrypt111111 = seedAuth.password;                          // every generated user logs in with 111111
print('reference: ' + Object.keys(routes).length + ' routes, ' + Object.keys(trainTypes).length + ' train types, ' + priceCfg.length + ' price configs');
priceCfg = priceCfg.filter(function (p) { return routes[p.routeId] && trainTypes[p.trainType]; });
if (!priceCfg.length) throw 'no coherent (trainType, routeId) price configs';

function letterFor(trainType) {
  if (/^GaoTie/i.test(trainType)) return 'G';
  if (/^DongChe/i.test(trainType)) return 'D';
  if (/^ZhiDa/i.test(trainType)) return 'Z';
  if (/^TeKuai/i.test(trainType)) return 'T';
  return 'K';
}

// ---------------------------------------------------------------- users
var U0 = dbAuth.user.count() - 2; if (U0 < 0) U0 = 0;   // generated users so far (2 are seeded)
var T0 = dbTravel.trip.count() + dbTravel2.trip.count();
reseed(U0, T0);
print('offsets: users +' + U0 + ', trips +' + T0 + ', seed ' + SEED + ' -> ' + _s);
var t0 = tsec(); var users = [];
var bA = [], bU = [], bC = [], bM = [], n = 0;
for (var i = 0; i < N_USERS; i++) {
  var id = uuidStr(), uname = 'user_' + pad(U0 + i, 7), doc = '' + (100000000000000000 + ri(900000000)) + pad(ri(1000000000), 9);
  users.push({id: id, name: uname, doc: doc, cname: 'Contact_' + pad(U0 + i, 7)});
  bA.push({_class: 'auth.entity.User', userId: juuid(id), username: uname, password: bcrypt111111, roles: ['ROLE_USER']});
  bU.push({_class: 'user.entity.User', userId: juuid(id), userName: uname, password: '111111', gender: 1 + ri(2), documentType: 1, documentNum: doc, email: uname + '@example.test'});
  bC.push({_id: juuid(uuidStr()), _class: 'contacts.entity.Contacts', accountId: juuid(id), name: 'Contact_' + pad(U0 + i, 7), documentType: 1, documentNumber: doc, phoneNumber: '1' + pad(ri(10000000000), 10)});
  bM.push({_id: uuidStr(), _class: 'inside_payment.entity.Money', userId: id, money: '10000', type: 'A'});
  if (bA.length >= BATCH) { n += flush(dbAuth.user, bA); flush(dbUser.user, bU); flush(dbContacts.contacts, bC); flush(dbInside.addMoney, bM); }
}
n += flush(dbAuth.user, bA); flush(dbUser.user, bU); flush(dbContacts.contacts, bC); flush(dbInside.addMoney, bM);
report('users (auth+user+contacts+addMoney x' + n + ')', n * 4, tsec() - t0);

// ---------------------------------------------------------------- trips
t0 = tsec(); var trips = [];
var bT1 = [], bT2 = [], nT = 0;
for (var i = 0; i < N_TRIPS; i++) {
  var pc = pick(priceCfg), route = routes[pc.routeId], letter = letterFor(pc.trainType);
  var number = '' + (10000 + T0 + i);
  var startH = 5 + ri(17), travelH = 2 + ri(10);
  var st = new Date(Date.UTC(2013, 4, 4, startH, ri(60), 0)), et = new Date(st.getTime() + travelH * 3600000);
  var mid = route.stations.length > 2 ? route.stations[1 + ri(route.stations.length - 2)] : route.stations[0];
  var t = {tripId: letter + number, letter: letter, number: number, trainType: pc.trainType, routeId: pc.routeId, startingTime: st, pc: pc};
  trips.push(t);
  var doc = {_id: {type: letter, number: number}, _class: null, trainTypeId: pc.trainType, routeId: pc.routeId,
             startingTime: st, startingStationId: route.startStationId, stationsId: mid, terminalStationId: route.terminalStationId, endTime: et};
  if (letter === 'G' || letter === 'D') { doc._class = 'travel.entity.Trip'; bT1.push(doc); } else { doc._class = 'travel2.entity.Trip'; bT2.push(doc); }
  if (bT1.length >= BATCH) nT += flush(dbTravel.trip, bT1);
  if (bT2.length >= BATCH) nT += flush(dbTravel2.trip, bT2);
}
nT += flush(dbTravel.trip, bT1) + flush(dbTravel2.trip, bT2);
report('trips (travel+travel2)', nT, tsec() - t0);
var tripsGD = trips.filter(function (t) { return t.letter === 'G' || t.letter === 'D'; });
var tripsOther = trips.filter(function (t) { return !(t.letter === 'G' || t.letter === 'D'); });
if (!tripsGD.length || !tripsOther.length) throw 'need both G/D and Z/T/K trips';

// ---------------------------------------------------------------- orders + payments
t0 = tsec();
var STATUS = [1,1,1,1,1,1,1,1,1,1, 2,2,2, 6,6,6,6, 0,0, 4, 5];   // weighted: paid, collected, used, notpaid, cancel, refund
var bO = [], bOO = [], bP = [], bIP = [], nO = 0, nP = 0;
var now = new Date();
for (var i = 0; i < N_ORDERS; i++) {
  var gd = (i % 2 === 0), trip = gd ? pick(tripsGD) : pick(tripsOther), route = routes[trip.routeId];
  var a = ri(route.stations.length - 1), b = a + 1 + ri(route.stations.length - a - 1);
  var dist = route.distances[b] - route.distances[a];
  var seatClass = ri(3) === 0 ? 2 : 3;
  var price = ((seatClass === 2 ? trip.pc.firstClassPriceRate : trip.pc.basicPriceRate) * dist).toFixed(1);
  var u = users[ri(users.length)], oid = uuidStr(), status = pick(STATUS);
  var travelDate = new Date(Date.UTC(2026, 8, 22 + ri(30)));
  var o = {_id: juuid(oid), _class: gd ? 'order.entity.Order' : 'other.entity.Order',
           boughtDate: new Date(now.getTime() - ri(90 * 86400000)), travelDate: travelDate, travelTime: trip.startingTime,
           accountId: juuid(u.id), contactsName: u.cname, documentType: 1, contactsDocumentNumber: u.doc,
           trainNumber: trip.tripId, coachNumber: 1 + ri(10), seatClass: seatClass,
           // numeric string: the seeded orders say "FirstClass-30", but the sold-seat path
           // does Integer.parseInt(seatNumber) and the real preserve flow writes the seat number
           seatNumber: '' + (1 + ri(60)),
           from: route.stations[a], to: route.stations[b], status: status, price: price};
  (gd ? bO : bOO).push(o);
  if (status === 1 || status === 2 || status === 6) {
    var pid = oid.replace(/-/g, '');
    bP.push({_id: pid, _class: 'com.trainticket.entity.Payment', orderId: oid, userId: u.id, price: price});
    bIP.push({_id: pid, _class: 'inside_payment.entity.Payment', orderId: oid, userId: u.id, price: price, type: 'P'});
  }
  if (bO.length >= BATCH) nO += flush(dbOrder.orders, bO);
  if (bOO.length >= BATCH) nO += flush(dbOrderOther.orders, bOO);
  if (bP.length >= BATCH) { nP += flush(dbPayment.payment, bP); flush(dbInside.payment, bIP); }
  if ((i + 1) % 200000 === 0) print('  ... ' + (i + 1) + ' orders, ' + ((tsec() - t0) / 1000).toFixed(0) + ' s');
}
nO += flush(dbOrder.orders, bO) + flush(dbOrderOther.orders, bOO);
nP += flush(dbPayment.payment, bP); flush(dbInside.payment, bIP);
report('orders', nO, tsec() - t0);
print('  payments: ' + nP + ' x2 collections (payment + inside_payment)');
print('totals: users=' + dbAuth.user.count() + ' trips=' + (dbTravel.trip.count() + dbTravel2.trip.count()) + ' orders=' + (dbOrder.orders.count() + dbOrderOther.orders.count()) + ' payments=' + dbPayment.payment.count());
