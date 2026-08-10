package com.marshaljlee.jxproxy.mobile

import android.annotation.SuppressLint
import android.os.Bundle
import android.text.InputType
import android.view.KeyEvent
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

/**
 * JXProxy Remote — a thin WebView shell around the Mac app's remote
 * web-control panel (Settings → System → Remote Web Control).
 *
 * Point it at http://<your-mac's-LAN-IP>:5355 and sign in with the proxy
 * auth token shown in JXProxy Settings → General.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var urlField: EditText
    private val prefs by lazy { getSharedPreferences("jxproxy", MODE_PRIVATE) }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val defaultUrl = "http://192.168.1.1:5355"
        val savedUrl = prefs.getString("serverURL", defaultUrl) ?: defaultUrl

        webView = WebView(this)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true // keeps the auth token in localStorage
        webView.settings.cacheMode = WebSettings.LOAD_DEFAULT
        webView.webViewClient = object : WebViewClient() {
            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError
            ) {
                if (request.isForMainFrame) {
                    Toast.makeText(
                        this@MainActivity,
                        "Can't reach ${view.url} — is Remote Web Control enabled on the Mac?",
                        Toast.LENGTH_LONG
                    ).show()
                }
            }
        }

        urlField = EditText(this)
        urlField.setText(savedUrl)
        urlField.hint = "http://mac-ip:5355"
        urlField.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        urlField.setOnEditorActionListener { _, _, _ -> load(urlField.text.toString()); true }

        val goButton = Button(this)
        goButton.text = "Go"
        goButton.setOnClickListener { load(urlField.text.toString()) }

        val topBar = LinearLayout(this)
        topBar.orientation = LinearLayout.HORIZONTAL
        topBar.addView(urlField, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        topBar.addView(goButton)

        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.addView(topBar)
        root.addView(webView, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            0,
            1f
        ))
        setContentView(root)

        load(savedUrl)
    }

    private fun load(rawUrl: String) {
        var url = rawUrl.trim()
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            url = "http://$url"
        }
        prefs.edit().putString("serverURL", url).apply()
        if (!urlField.text.toString().equals(url, ignoreCase = true)) {
            urlField.setText(url)
        }
        webView.loadUrl(url)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK && webView.canGoBack()) {
            webView.goBack()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }
}
