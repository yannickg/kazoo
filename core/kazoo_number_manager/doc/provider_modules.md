## Hooking a Provider's API into Kazoo

Service providers offer various add-ons to telephony; things like CNAM, E911, and other services can be added to numbers in **Kazoo**. Creating a provider module links **Kazoo** up with the provider's APIs.

## Overview

Provider modules exist as part of the core's `kazoo_number_manager` application. You can view existing modules in `core/kazoo_number_manager/src/providers/` to help guide your development efforts. The exported interface varies based on the type of service being provided. 

Services include:
```
E911
CNAM
Porting
Failover
Prepend
```
