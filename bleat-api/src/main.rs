use bleat_api::{
    config::Config, database::connect_and_migrate, observability::Observability, router,
};
use clap::Parser;
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = Config::try_from(bleat_api::config::Arguments::parse())?;
    let observability = Observability::install(&config)?;
    let database = connect_and_migrate(&config.database).await?;
    let listener = TcpListener::bind(config.bind_address).await?;

    tracing::info!(
        bind_address = %config.bind_address,
        deployment_environment = %config.deployment_mode,
        otlp_traces_enabled = config.telemetry.traces_enabled,
        otlp_logs_enabled = config.telemetry.logs_enabled,
        "bleat-api started"
    );

    axum::serve(listener, router(&config, database))
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    observability.shutdown();
    Ok(())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};

        let mut terminate = match signal(SignalKind::terminate()) {
            Ok(terminate) => terminate,
            Err(error) => {
                tracing::error!(error = %error, "failed to install SIGTERM handler");
                if let Err(error) = tokio::signal::ctrl_c().await {
                    tracing::error!(error = %error, "failed to install Ctrl-C handler");
                }
                return;
            }
        };
        tokio::select! {
            result = tokio::signal::ctrl_c() => {
                if let Err(error) = result {
                    tracing::error!(error = %error, "failed to install Ctrl-C handler");
                }
            }
            _ = terminate.recv() => {}
        }
    }

    #[cfg(not(unix))]
    if let Err(error) = tokio::signal::ctrl_c().await {
        tracing::error!(error = %error, "failed to install Ctrl-C handler");
    }
}
