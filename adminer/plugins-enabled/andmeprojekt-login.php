<?php

require_once('/var/www/html/plugins/login-servers.php');

class AndmeprojektLogin extends AdminerLoginServers {
    function __construct() {
        parent::__construct(array(
            'PostgreSQL andmeprojekt' => array(
                'server' => 'postgres',
                'driver' => 'pgsql',
            ),
        ));
    }

    function loginFormField($name, $heading, $value) {
        if ($name == 'username') {
            $username = $_GET['username'] ?: 'andrus';
            return $heading . '<input name="auth[username]" id="username" autofocus value="'
                . htmlspecialchars($username, ENT_QUOTES, 'UTF-8')
                . '" autocomplete="username" autocapitalize="off">';
        }

        if ($name == 'db') {
            $db = $_GET['db'] ?: 'andmeprojekt';
            return $heading . '<input name="auth[db]" value="'
                . htmlspecialchars($db, ENT_QUOTES, 'UTF-8')
                . '" autocapitalize="off">';
        }

        return parent::loginFormField($name, $heading, $value);
    }
}

return new AndmeprojektLogin();
