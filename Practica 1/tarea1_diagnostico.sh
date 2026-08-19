#!/bin/bash
# tarea1_diagnostico.sh
# Script de bienvenida / diagnóstico inicial - Nodo Linux
# Muestra: nombre del equipo, IP actual y espacio en disco

echo "=========================================="
echo "   DIAGNOSTICO DE SISTEMA - $(date)"
echo "=========================================="

echo ""
echo "--- Informacion del equipo ---"
echo "Hostname: $(hostname)"
echo "Sistema Operativo: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"

echo ""
echo "--- Direcciones IP ---"
ip -4 addr show | grep inet | grep -v 127.0.0.1 | awk '{print "Interfaz " $NF ": " $2}'

echo ""
echo "--- Espacio en disco ---"
df -h --output=source,size,used,avail,pcent,target | grep -E '^/dev/'

echo ""
echo "--- Estado de red interna ---"
if ip addr show | grep -q "192.168.50."; then
    echo "Adaptador de Red Interna (red_sistemas): OK"
else
    echo "ADVERTENCIA: No se detecto IP en el rango 192.168.50.0/24"
fi

echo ""
echo "=========================================="
echo "   FIN DEL DIAGNOSTICO"
echo "=========================================="