// Coherence check: sample orders from both order stores and follow every reference.
var N = typeof N !== 'undefined' ? N : 300;
function rev8(x) { var o = ''; for (var i = 14; i >= 0; i -= 2) o += x.substr(i, 2); return o; }
function juuid(s) { var h = s.replace(/-/g, ''); return HexData(3, rev8(h.substr(0, 16)) + rev8(h.substr(16, 16))); }
var dbAuth = connect('ts-auth-mongo:27017/ts-auth-mongo'), dbUser = connect('ts-user-mongo:27017/ts-user-mongo');
var dbRoute = connect('ts-route-mongo:27017/ts'), dbTrain = connect('ts-train-mongo:27017/ts'), dbPrice = connect('ts-price-mongo:27017/ts');
var dbTravel = connect('ts-travel-mongo:27017/ts'), dbTravel2 = connect('ts-travel2-mongo:27017/ts');
var dbPayment = connect('ts-payment-mongo:27017/ts'), dbInside = connect('ts-inside-payment-mongo:27017/ts');
var bad = {user: 0, trip: 0, route: 0, trainType: 0, price: 0, fromto: 0, payment: 0, insidePayment: 0}, seen = 0;
[connect('ts-order-mongo:27017/ts'), connect('ts-order-other-mongo:27017/ts')].forEach(function (dbO) {
  dbO.orders.aggregate([{$sample: {size: N}}]).forEach(function (o) {
    seen++;
    if (!dbAuth.user.findOne({userId: o.accountId}) || !dbUser.user.findOne({userId: o.accountId})) bad.user++;
    var tid = {type: o.trainNumber.substr(0, 1), number: o.trainNumber.substr(1)};
    var trip = dbTravel.trip.findOne({_id: tid}) || dbTravel2.trip.findOne({_id: tid});
    if (!trip) { bad.trip++; return; }
    var route = dbRoute.routes.findOne({_id: trip.routeId});
    if (!route) bad.route++;
    if (!dbTrain.trainType.findOne({_id: trip.trainTypeId})) bad.trainType++;
    if (!dbPrice.price_config.findOne({trainType: trip.trainTypeId, routeId: trip.routeId})) bad.price++;
    if (route && !(route.stations.indexOf(o.from) >= 0 && route.stations.indexOf(o.to) > route.stations.indexOf(o.from))) bad.fromto++;
  });
});
// exact payment linkage: sample payments and check the order exists with the same price
var pbad = 0, pseen = 0;
dbPayment.payment.aggregate([{$sample: {size: N}}]).forEach(function (p) {
  pseen++;
  var o = connect('ts-order-mongo:27017/ts').orders.findOne({_id: juuid(p.orderId)}) ||
          connect('ts-order-other-mongo:27017/ts').orders.findOne({_id: juuid(p.orderId)});
  if (!o || o.price !== p.price || !dbInside.payment.findOne({_id: p._id})) pbad++;
});
print('orders sampled: ' + seen + '  dangling: ' + JSON.stringify(bad));
print('payments sampled: ' + pseen + '  dangling/mismatched: ' + pbad);
