Ext.onReady (function () {
    jarvisInit ('demo');

    // this holds our staff names
    var staff_names_store = new Ext.data.JsonStore ({
        url: jarvisUrl ('user_names'),
        root: 'data',
        idProperty: 'id',
        fields: ['id', 'name'],
        displayField: 'name'
    });

    var username_field = new Ext.form.ComboBox ({
        renderTo: 'username',
        store: staff_names_store,
        mode: 'local',
        emptyText: 'Select Username...',
        displayField: 'name',
        valueField: 'name',
        forceSelection: true
    });
    var password_field = new Ext.form.TextField ({
        renderTo: 'password'
    });
    var login_button = new Ext.Button ({
        renderTo: 'button',
        text: 'Login',
        listeners: { 'click': function () { doLogin () } }
    });

    // Attempt to login.  Set our cookies, and reload the "status" store.
    function doLogin () {
        var params = {
            username: username_field.getValue (),
            password: password_field.getValue ()
        };
        Ext.Ajax.request({
            url: jarvisUrl ('__status'),
            params: params,

            // We received a response back from the server, that's a good start.
            success: function (response, request_options) {
                try {
                    var result = Ext.util.JSON.decode (response.responseText);

                    if (result.error_string == '') {
                        document.getElementById ("request_text").innerHTML = 'You may now access the Demo application.';
                        document.getElementById ("feedback_text").style.color = '#444';
                        var outgoing = '<p>Login Accepted (User = ' + result.username;
                        if (result.group_list != '') {
                            outgoing = outgoing + ', Groups = ' + result.group_list;
                        }
                        outgoing = outgoing + ').</p>\n';
                        var from = jarvisQueryArg (document.URL, 'from');
                        if (from) {
                            outgoing = outgoing + '<p>Return to <a href="' + from + '">' + from + '</a>.</p>\n';
                        } else {
                            outgoing = outgoing + '<p>Go to the <a href="/edit/index.html">Index</a>.</p>\n';
                        }
                        document.getElementById ("feedback_text").innerHTML = outgoing;

                    } else {
                        document.getElementById ("request_text").innerHTML = 'You must login before you can access the Demo application.';
                        document.getElementById ("feedback_text").style.color = '#CC6600';
                        document.getElementById ("feedback_text").innerHTML = result.error_string;
                    }

                // Well, something bad here.  Could be anything.  We tried.
                } catch (e) {
                    document.getElementById ("feedback_text").innerHTML = response.responseText;
                }
            },
            failure: function (response, request_options) {
                document.getElementById ("feedback_text").innerHTML = response.responseText;
            }
        });
    }
    function doLoginOnEnter (field, e) {
        if (e.getKey () == Ext.EventObject.ENTER) {
            doLogin ();
        }
    }

    username_field.setValue ();
    password_field.setValue ();

    password_field.addListener("specialkey", doLoginOnEnter);

    staff_names_store.load();
});
