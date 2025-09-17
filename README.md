# Griffin-Relay-expert 🤖

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform](https://img.shields.io/badge/Platform-MetaTrader_5-0053A6)](https://www.metatrader5.com)

A "slave" Expert Advisor for MetaTrader 5 that connects to the `Griffin-Relay-server`. It fetches trade signals via HTTP polling and executes them on a trading account with automated risk-based lot sizing.

This EA is designed to be lightweight, efficient, and easy to set up, with no external library dependencies.

---

## ✨ Features

-   **HTTP Polling:** Uses the native MQL5 `WebRequest` function to periodically fetch signals, eliminating the need for complex WebSocket libraries or DLLs.
-   **Zero Dependencies:** Fully self-contained. It does **not** require any third-party `.mqh` libraries (like JAson.mqh) for its core functionality.
-   **Risk-Based Lot Sizing:** Automatically calculates the trade volume based on a user-defined risk percentage (`InpRiskPercent`) and the signal's stop-loss level.
-   **Batch Signal Processing:** Capable of processing an entire array of trade signals received in a single HTTP response.
-   **Symbol Filtering:** Protects against incorrect trades by only executing signals that match the symbol of the chart it's running on.
-   **Customizable Settings:** Easily configure the server URL, risk, and magic number via the EA's input parameters.

---

## 🛠️ Installation & Setup

This EA requires the `Griffin-Relay-server` to be running.

### Step 1: Download & Compile the EA

1.  Download the `SignalReceiverHttp.mq5` file from this repository.
2.  Open MetaTrader 5.
3.  Go to `File` -> `Open Data Folder`.
4.  Navigate to the `MQL5\Experts` directory.
5.  Place the downloaded `.mq5` file here.
6.  Return to MetaTrader 5, open the "Navigator" window, right-click on "Expert Advisors", and select "Refresh".
7.  The `SignalReceiverHttp` EA should now appear. Double-click it to open it in MetaEditor and click "Compile". It should compile without any errors.

### Step 2: IMPORTANT - Allow WebRequest in MetaTrader 5

For the EA to communicate with the server, you **must** enable `WebRequest` in the MT5 options.

1.  In MetaTrader 5, go to `Tools` -> `Options`.
2.  Select the **"Expert Advisors"** tab.
3.  Check the box that says **"Allow WebRequest for listed URL"**.
4.  Click the "Add new URL" button and enter the address of your server: `http://localhost:5002`
5.  Click "OK" to save the settings.



---

## 🚀 Usage

1.  Ensure the `Griffin-Relay-server` is running.
2.  In MetaTrader 5, drag the `SignalReceiverHttp` EA from the Navigator onto the chart of the symbol you want to trade (e.g., EURUSD).
3.  In the "Inputs" tab, configure the parameters:
    -   **`InpServerURL`**: Should match the server address (`http://localhost:5002/get-signals`).
    -   **`InpRiskPercent`**: The percentage of your account balance to risk per trade (e.g., `1.0` for 1%).
    -   **`InpMagicNumber`**: A unique number to identify trades opened by this EA.
4.  Click "OK".
5.  Make sure the **"Algo Trading"** button in your MetaTrader 5 toolbar is enabled (green).

The EA will now poll the server every 5 seconds (by default) for new signals and execute them automatically.

---

## 📜 License

This project is open-source and licensed under the **GNU General Public License v3.0**. See the [LICENSE](LICENSE) file for details.