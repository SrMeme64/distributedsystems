# Entorno productivo

Este entorno no tiene una raíz Terraform aplicable. KVM/libvirt fue elegido
para el laboratorio local; no es una decisión de plataforma productiva.
Antes de crear esta configuración se debe definir el destino productivo, la
red, el almacenamiento, el registro de imágenes, TLS y el manejo de secretos.
No copies la configuración local ni la apliques en Minikube.
