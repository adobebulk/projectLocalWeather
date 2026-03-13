#ifndef WEATHER_COMPUTER_INGRESS_ROUTER_H
#define WEATHER_COMPUTER_INGRESS_ROUTER_H

#include <Arduino.h>

#include "protocol_parser.h"

namespace ingress_router {

void handlePacket(const protocol_parser::ParseResult& result, Stream& serial);

}  // namespace ingress_router

#endif  // WEATHER_COMPUTER_INGRESS_ROUTER_H
