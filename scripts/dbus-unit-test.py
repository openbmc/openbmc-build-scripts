#!/usr/bin/env python

"""
This script launches a dbus session, sets the DBUS_SESSION_BUS_ADDRESS
and DBUS_STARTER_BUS_TYPE Eenvironment variables and puts the generated files
in the dbus dir location passed as a parameter. It then runs the unit test
script, and then cleans up the generated dbus files.
"""

from subprocess import check_call, check_output
import os
import sys
import argparse
import re
import tempfile

def mangle_dbus_config(dbus_dir, system, local):
    dbus_pid = os.path.join(dbus_dir, 'pid')
    dbus_socket = os.path.join(dbus_dir, 'system_bus_socket')
    for line in system:
        line = re.sub('<type>.*</type>','<type>session</type>', \
                      line, flags=re.DOTALL)
        line = re.sub('<pidfile>.*</pidfile>', \
                      '<pidfile>%s</pidfile>' % dbus_pid, \
                      line, flags=re.DOTALL)
        line = re.sub('<listen>.*</listen>', \
                      '<listen>unix:path=%s</listen>' % dbus_socket, \
                      line, flags=re.DOTALL)
        line = re.sub('<deny','<allow', line)
        local.write(line)

def launch_session_dbus(dbus_dir, system):
    """
    Launches a session debus using a modified config file and
    sets the DBUS_SESSION_BUS_ADDRESS environment variable

    Parameter descriptions:
    dbus_dir            Directory location for generated files
    dbus_config_file    File location of dbus sys config file
    """
    local = os.path.join(dbus_dir,'system-local.conf')
    with open(system) as infile, open(local, 'w') as outfile:
        mangle_dbus_config(dbus_dir, infile, outfile)

    dbus_pid = os.path.join(dbus_dir,'pid')
    if os.path.isfile(dbus_pid):
        os.remove(dbus_pid)

    command = ['dbus-daemon', '--config-file=%s' % local, \
               '--print-address']
    out = check_output(command).splitlines()
    os.environ['DBUS_SESSION_BUS_ADDRESS'] = out[0]
    os.environ['DBUS_STARTER_BUS_TYPE'] = 'session'

def dbus_cleanup(dbus_dir):
    """
    Kills the dbus session started by launch_session_dbus
    and removes the generated files.

    Parameter descriptions:
    dbus_dir            Directory location of generated files
    """

    dbus_pid = os.path.join(dbus_dir,'pid')
    dbus_socket = os.path.join(dbus_dir,'system_bus_socket')
    dbus_local_conf = os.path.join(dbus_dir,'system-local.conf')
    if os.path.isfile(dbus_pid):
        dbus_pid = open(dbus_pid,'r').read().replace('\n','')
        check_call(['kill', dbus_pid])
    if os.path.isfile(dbus_local_conf):
        os.remove(dbus_local_conf)
    if os.path.exists(dbus_socket):
        os.remove(dbus_socket)


if __name__ == '__main__':

    # Set command line arguments
    parser = argparse.ArgumentParser()

    parser.add_argument("-f", "--dbussysconfigfile",
                        dest="DBUS_SYS_CONFIG_FILE",
                        help="Dbus sys config file location")
    parser.add_argument("-u", "--unittestandparams",
                        dest="UNIT_TEST",
                        help="Unit test script and params as comma delimited string")
    parser.add_argument("-m", "--mangle", action='store_true',
                        help="Mangle a DBus configuration file. Requires --directory")
    parser.add_argument("-d", "--directory",
                        help="The DBus state directory. Required for --mangle")
    args = parser.parse_args(sys.argv[1:])
    DBUS_DIR = tempfile.mkdtemp() if args.directory is None else args.directory
    DBUS_SYS_CONFIG_FILE = args.DBUS_SYS_CONFIG_FILE
    UNIT_TEST = args.UNIT_TEST

    if args.mangle:
        mangle_dbus_config(DBUS_DIR, sys.stdin, sys.stdout)
        sys.exit(0)

    launch_session_dbus(DBUS_DIR, DBUS_SYS_CONFIG_FILE)
    check_call(UNIT_TEST.split(','), env=os.environ)
    dbus_cleanup(DBUS_DIR)
